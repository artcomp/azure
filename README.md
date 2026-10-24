# Deploy de Application Insights + Log Analytics no Azure (Bicep + Gitea Actions)

Workflow de CI/CD que provisiona um **Log Analytics Workspace** e um **Azure Application Insights** (workspace-based) usando **Bicep**, executado pelo **Gitea Actions** dentro da imagem oficial **`mcr.microsoft.com/azure-cli`**.

Tudo (validação, login, resource group, naming e deploy) vive em **um único workflow**, sem dependências externas além das secrets de Azure.

> O Application Insights moderno (workspace-based) **exige** um Log Analytics Workspace — por isso o workflow cria os dois juntos, no mesmo Resource Group e na mesma região.

## Como funciona

1. Você dispara o workflow via `workflow_dispatch` informando **nome da aplicação**, **ambiente** e **região**.
2. O runner sobe o container da imagem oficial do Azure CLI.
3. O workflow valida os inputs, autentica no Azure (service principal), garante que o Resource Group exista, calcula o próximo contador de nome (compartilhado entre os dois recursos), gera o template Bicep inline e executa o deploy do par Log Analytics + App Insights.

## Inputs

| Input        | Tipo     | Opções                              | Obrigatório |
| ------------ | -------- | ----------------------------------- | ----------- |
| `app_name`   | `string` | `a-z`, `0-9`, hífens (2–41 chars)   | Sim         |
| `environment`| `choice` | `dev`, `homolog`, `prod`            | Sim         |
| `region`     | `choice` | `eastus`, `eastus2`, `brazilsouth`  | Sim         |

> `app_name` é normalizado para **lowercase** antes de validar. Ex.: `MeuApp` → `meuapp`.

## Convenção de nomes

| Recurso              | Padrão                                    | Exemplo                                  |
| -------------------- | ----------------------------------------- | ---------------------------------------- |
| Resource Group       | `<ambiente>-rg-<app>`                     | `homolog-rg-meuapp`                      |
| Log Analytics        | `<ambiente>-log-<app>-<regiao>-<NNN>`     | `homolog-log-meuapp-brazilsouth-001`     |
| Application Insights | `<ambiente>-appi-<app>-<regiao>-<NNN>`    | `homolog-appi-meuapp-brazilsouth-001`    |

Regras:

- O **contador `NNN`** é sequencial (`001`, `002`, …) e é o **mesmo para os dois recursos** de uma mesma execução — o nome do Log Analytics é idêntico ao do App Insights, apenas com `log` no lugar de `appi`.
- O valor é `max + 1`, considerando **o maior sufixo já existente no RG** para **ambos** os prefixos (`…-appi-…-NNN` e `…-log-…-NNN`). Isso evita colisão de nome mesmo que um dos recursos tenha sido apagado separadamente.
- Falha com erro se o contador passar de `999`.
- O prefixo usa o valor do ambiente **exatamente como escolhido** (`dev` / `homolog` / `prod`).

Exemplo com `app_name=meuapp`, `environment=homolog`, `region=brazilsouth`:

```
homolog-rg-meuapp
├── homolog-log-meuapp-brazilsouth-001   ← Log Analytics Workspace
└── homolog-appi-meuapp-brazilsouth-001  ← Application Insights (ligado ao workspace acima)
```

## Pré-requisitos

### 1. Runner do Gitea Actions

O workflow usa a label `ubuntu-latest`. Seu runner precisa declará-la, por exemplo:

```yaml
labels:
  - "ubuntu-latest:docker://docker.gitea.com/runner-images:ubuntu-latest"
```

### 2. Secrets no repositório (Gitea → Settings → Secrets e variáveis → Actions)

| Secret                 | Descrição                                    |
| ---------------------- | -------------------------------------------- |
| `AZURE_CLIENT_ID`      | Application (client) ID do service principal |
| `AZURE_CLIENT_SECRET`  | Client secret do service principal           |
| `AZURE_TENANT_ID`      | Tenant (directory) ID                        |
| `AZURE_SUBSCRIPTION_ID`| Subscription ID de destino                   |

O service principal precisa das permissões mínimas descritas na seção [Permissões RBAC mínimas](#permissões-rbac-mínimas).

## Uso

1. Copie o arquivo para o seu repositório:

   ```
   .gitea/workflows/deploy-app-insights.yml
   ```

2. Push para a branch padrão (o `workflow_dispatch` só aparece na branch padrão).

3. No Gitea: **Ações → Deploy App Insights + Log Analytics (Bicep) → Run workflow** e preencha os 3 inputs.

4. Acompanhe o log. Ao final, um **step summary** mostra ambiente, região, RG e os nomes do Log Analytics e do App Insights criados.

## Permissões RBAC mínimas

O workflow executa exatamente estas operações ARM:

| Operação | Comando | Ação ARM necessária |
| -------- | ------- | ------------------- |
| Verificar/criar RG | `az group exists` / `az group create` | `Microsoft.Resources/resourceGroups/read` + `write` |
| Criar deployment | `az deployment group create` | `Microsoft.Resources/deployments/read` + `write` |
| Listar recursos no RG | `az resource list -g <rg> -t <tipo>` | `Microsoft.Resources/resourceGroups/resources/read` |
| Criar Log Analytics | template Bicep | `Microsoft.OperationalInsights/workspaces/read` + `write` |
| Criar App Insights | template Bicep | `Microsoft.Insights/components/read` + `write` |

> **Escopo:** `resourceGroups/*` e `deployments/*` são avaliados na **subscription** (o RG pode ainda não existir), então o `AssignableScopes` precisa ser a subscription (ou um Management Group acima dela).

### Role customizada (mínima)

Crie a role com `New-AzRoleDefinition` / `az role definition create`:

```json
{
  "Name": "App Insights Deployer",
  "IsCustom": true,
  "Description": "Permissoes minimas para criar Log Analytics Workspace + Application Insights via Bicep",
  "AssignableScopes": [ "/subscriptions/<SUBSCRIPTION_ID>" ],
  "Actions": [
    "Microsoft.Resources/resourceGroups/read",
    "Microsoft.Resources/resourceGroups/write",
    "Microsoft.Resources/resourceGroups/resources/read",
    "Microsoft.Resources/deployments/read",
    "Microsoft.Resources/deployments/write",
    "Microsoft.OperationalInsights/workspaces/read",
    "Microsoft.OperationalInsights/workspaces/write",
    "Microsoft.Insights/components/read",
    "Microsoft.Insights/components/write"
  ],
  "NotActions": [],
  "DataActions": [],
  "NotDataActions": []
}
```

```bash
az role definition create --role-definition @appi-deployer-role.json
az role assignment create \
  --assignee <AZURE_CLIENT_ID> \
  --role "App Insights Deployer" \
  --scope /subscriptions/<SUBSCRIPTION_ID>
```

### Alternativa (mais simples, menos mínima)

Ajuste o `AssignableScopes` para o Management Group/Subscription e use a built-in **`Contributor`** — cobre tudo acima, mas dá acesso de escrita a quase todos os recursos da subscription. Prefira a role customizada se o princípio de menor privilégio for obrigatório.

### Observações

- `*/delete` **não** é necessário: o deploy usa modo incremental (padrão do `az deployment group create`) e não apaga recursos.
- Se algum step falhar com `AuthorizationFailed`, compare a ação exata citada no erro com a lista acima e acrescente apenas o que faltar em `Actions`.

## Estrutura

```
.
├── README.md
└── .gitea/
    └── workflows/
        └── deploy-app-insights.yml   # workflow único (Bicep inline)
```

## Lógica do workflow (steps)

| # | Step                           | O que faz                                                                 |
| - | ------------------------------ | ------------------------------------------------------------------------- |
| 1 | Validar inputs e derivar nomes | Lowercase + regex no `app_name`; valida `environment`/`region`; monta RG, prefixo `appi` e prefixo `log` |
| 2 | Login Azure                    | `az login --service-principal` + `az account set` (falha se secret ausente) |
| 3 | Garantir Resource Group        | `az group exists` → cria com `az group create` se necessário              |
| 4 | Calcular próximo contador      | Lista `components` **e** `workspaces` no RG, pega o `max` entre os dois prefixos, soma 1 → mesmo `NNN` para os dois nomes |
| 5 | Gerar template Bicep           | Grava `infra/main.bicep` inline (heredoc) com LAW + App Insights          |
| 6 | Deploy via Bicep               | `az bicep install` + `az deployment group create` (LAW primeiro, via `dependsOn`) |
| 7 | Resumo                         | Escreve tabela no `$GITHUB_STEP_SUMMARY` (roda `always()`)                |

### Concorrência

Um `concurrency` group por `ambiente + app_name` com `cancel-in-progress: false` evita duas execuções simultâneas disputando o mesmo contador.

## Template Bicep

```bicep
param appiName string
param logName string
param location string

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appiName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id   // liga o App Insights ao workspace
  }
}

output appiName string = appInsights.name
output logName string = logAnalytics.name
output connectionString string = appInsights.properties.ConnectionString
```

- **SKU do workspace**: `PerGB2018` (pay-as-you-go), retenção de 30 dias.
- **`WorkspaceResourceId`** torna o App Insights *workspace-based* (modelo atual); o Bicep injeta o `dependsOn` automático, garantindo que o LAW seja criado primeiro.

## Notas

- **Imagem**: `mcr.microsoft.com/azure-cli:latest` (Azure Linux). Para reprodutibilidade, troque por uma tag fixa, ex.: `2.74.0-azurelinux3.0`.
- **Bicep**: instalado no step via `az bicep install` (não vem pré-instalado na imagem).
- **Autenticação**: direto via `az login` no container — não usa a action `azure/login`.
- **Modo de deploy**: incremental (padrão do `az deployment group create`).
