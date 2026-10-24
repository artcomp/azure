# Deploy de Application Insights + Log Analytics no Azure (Bicep + Gitea Actions)

Workflow de CI/CD que provisiona um **Log Analytics Workspace** e um **Azure Application Insights** (workspace-based) usando **Bicep**, executado pelo **Gitea Actions** com **actions oficiais da Microsoft** (`azure/login`, `azure/bicep-deploy`) — sem bash embutido de login/deploy e sem template gerado inline.

> O Application Insights moderno (workspace-based) **exige** um Log Analytics Workspace — por isso o deploy cria os dois juntos, no mesmo Resource Group e na mesma região.

## Arquitetura

```
workflow_dispatch (app_name, environment, region, dry_run)
        │
        ▼
┌─ job: deploy  (container: artcomp/azure-cli-node:latest → az + node24 + git) ─┐
│  1. actions/checkout@v4                                                       │
│  2. azure/login@v2                (SP via secret AZURE_CREDENTIALS)           │
│  3. ./.gitea/actions/resolve-appi-names   (valida + nomes + contador NNN)     │
│  4. azure/bicep-deploy@v2         (scope: subscription, create|whatIf)        │
│       └─ infra/deploy.bicep → RG + módulo LAW + módulo App Insights           │
│  5. Resumo (step summary, always())                                           │
└───────────────────────────────────────────────────────────────────────────────┘
```

Por que uma imagem própria? As actions oficiais são **Node24** e internamente usam o **Azure CLI**. A imagem oficial do Azure CLI não tem Node; a imagem do runner do Gitea não tem `az`. O `docker/Dockerfile` une os dois (testado: `azure-cli:2.91.0` + `tdnf install nodejs` → **node v24.22.1**).

> `azure/arm-deploy` está sendo **descontinuada** pela Microsoft; este fluxo usa o substituto oficial **[`azure/bicep-deploy`](https://github.com/Azure/bicep-deploy)**, feito para Bicep, com suporte a *what-if* e *deployment stacks*.

## Estrutura do repositório

```
.
├── README.md
├── docker/
│   └── Dockerfile                          # imagem do job: Azure CLI + node24 + git
├── .gitea/
│   ├── actions/
│   │   └── resolve-appi-names/
│   │       ├── action.yml                  # composite action (inputs/outputs)
│   │       └── resolve.sh                  # validação + nomes + contador NNN
│   └── workflows/
│       └── deploy-app-insights.yml         # orquestração fina (5 steps)
└── infra/
    ├── deploy.bicep                        # targetScope = subscription (cria RG + módulos)
    └── modules/
        ├── log-analytics.bicep             # Log Analytics Workspace (PerGB2018, 30d)
        └── app-insights.bicep              # App Insights workspace-based
```

## Inputs

| Input         | Tipo     | Opciones                             | Obrigatório |
| ------------- | -------- | ------------------------------------ | ----------- |
| `app_name`    | `string` | `a-z`, `0-9`, hífens (2–41 chars)    | Sim         |
| `environment` | `choice` | `dev`, `homolog`, `prod`             | Sim         |
| `region`      | `choice` | `eastus`, `eastus2`, `brazilsouth`   | Sim         |
| `dry_run`     | `boolean`| `true` simula (what-if), `false` cria| Não (false) |

> `app_name` é normalizado para **lowercase** antes de validar. Ex.: `MeuApp` → `meuapp`.

## Convenção de nomes

| Recurso              | Padrão                                    | Exemplo                                  |
| -------------------- | ----------------------------------------- | ---------------------------------------- |
| Resource Group       | `<ambiente>-rg-<app>`                     | `homolog-rg-meuapp`                      |
| Log Analytics        | `<ambiente>-log-<app>-<regiao>-<NNN>`     | `homolog-log-meuapp-brazilsouth-001`     |
| Application Insights | `<ambiente>-appi-<app>-<regiao>-<NNN>`    | `homolog-appi-meuapp-brazilsouth-001`    |

Regras:

- O **contador `NNN`** é sequencial (`001`, `002`, …) e é o **mesmo para os dois recursos** de uma mesma execução — o nome do Log Analytics é idêntico ao do App Insights, apenas com `log` no lugar de `appi`.
- O valor é `max + 1`, considerando **o maior sufixo já existente no RG** para **ambos** os prefixos (`…-appi-…-NNN` e `…-log-…-NNN`). Evita colisão mesmo que um dos recursos tenha sido apagado separadamente.
- Falha com erro se o contador passar de `999`.
- O prefixo usa o ambiente **exatamente como escolhido** (`dev` / `homolog` / `prod`).
- No primeiro deploy (RG ainda não existe) o contador começa em `001`.

## Pré-requisitos

### 1. Imagem do job (`artcomp/azure-cli-node`)

A imagem precisa de **Azure CLI + Node.js 24 + git**. Construa e publique uma vez:

```bash
docker build -t artcomp/azure-cli-node:latest -f docker/Dockerfile .
docker push artcomp/azure-cli-node:latest
```

Opções de registro:

| Registro                  | Como referenciar                              | Observação                                              |
| ------------------------- | --------------------------------------------- | ------------------------------------------------------- |
| Docker Hub (público)      | `artcomp/azure-cli-node:latest`               | Runner puxa anonimamente — mais simples                 |
| Package registry do Gitea | `localhost:3000/<usuario>/azure-cli-node:latest` | Requer `docker login <host>` no **host** do runner   |

Se usar outra tag/registro, ajuste `jobs.deploy.container.image` no workflow.

### 2. Runner do Gitea Actions

O workflow usa a label `ubuntu-latest`. Seu runner precisa declará-la, por exemplo:

```yaml
labels:
  - "ubuntu-latest:docker://docker.gitea.com/runner-images:ubuntu-latest"
```

O `container.image` do job sobrescreve a imagem da label; a label serve apenas para enfileirar o job.

### 3. Secrets no repositório (Gitea → Settings → Secrets e variáveis → Actions)

| Secret                  | Descrição                                                                 |
| ----------------------- | ------------------------------------------------------------------------- |
| `AZURE_CREDENTIALS`     | JSON do service principal (formato abaixo)                                |
| `AZURE_SUBSCRIPTION_ID` | Subscription ID de destino (usado pela action de deploy)                   |

Formato do `AZURE_CREDENTIALS`:

```json
{
  "clientId": "<APPLICATION_CLIENT_ID>",
  "clientSecret": "<CLIENT_SECRET>",
  "tenantId": "<TENANT_ID>",
  "subscriptionId": "<SUBSCRIPTION_ID>"
}
```

Gerando o SP (com a role customizada da seção RBAC):

```bash
az ad sp create-for-rbac \
  --name "sp-appi-deployer" \
  --role "App Insights Deployer" \
  --scopes /subscriptions/<SUBSCRIPTION_ID>
```

> A saída do comando já vem em JSON compatível (`clientId`/`clientSecret`/`tenantId`). Cole como valor do secret `AZURE_CREDENTIALS`. Alternativamente, crie o client secret manualmente no Entra ID e monte o JSON.

O service principal precisa das permissões mínimas descritas em [Permissões RBAC mínimas](#permissões-rbac-mínimas).

## Uso

1. Push para a branch padrão (o `workflow_dispatch` só aparece na branch padrão).
2. No Gitea: **Ações → Deploy App Insights + Log Analytics (Bicep) → Run workflow** e preencha os inputs.
3. Para **simular sem alterar nada**, marque `dry_run` → o deploy roda em modo *what-if*.
4. Ao final, o **step summary** mostra ambiente, região, modo, RG e os nomes criados.

Outputs do step `deploy` disponíveis para steps/jobs seguintes: `rgName`, `logName`, `appiName` e `connectionString` (mascarado nos logs via `masked-outputs`).

### Concorrência

Um `concurrency` group por `ambiente + app_name` com `cancel-in-progress: false` evita duas execuções simultâneas disputando o mesmo contador.

## Permissões RBAC mínimas

O workflow executa exatamente estas operações ARM:

| Operação                          | Quem executa                        | Ação ARM necessária                                              |
| --------------------------------- | ----------------------------------- | ---------------------------------------------------------------- |
| Verificar existência do RG        | `resolve.sh` (`az group exists`)    | `Microsoft.Resources/resourceGroups/read`                        |
| Listar recursos no RG (contador)  | `resolve.sh` (`az resource list`)   | `Microsoft.Resources/resourceGroups/resources/read`              |
| Criar RG + deployment (sub scope) | `azure/bicep-deploy@v2`             | `Microsoft.Resources/resourceGroups/write` + `deployments/read` + `deployments/write` |
| Criar Log Analytics               | módulo Bicep                        | `Microsoft.OperationalInsights/workspaces/read` + `write`        |
| Criar App Insights                | módulo Bicep                        | `Microsoft.Insights/components/read` + `write`                   |

> **Escopo:** o deploy é feito no escopo da **subscription** (o template cria o RG), então o `AssignableScopes` precisa ser a subscription (ou um Management Group acima dela).

### Role customizada (mínima)

```json
{
  "Name": "App Insights Deployer",
  "IsCustom": true,
  "Description": "Permissoes minimas para criar Resource Group, Log Analytics Workspace + Application Insights via Bicep",
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

Use a built-in **`Contributor`** no escopo da subscription — cobre tudo acima, mas dá acesso de escrita a quase todos os recursos. Prefira a role customizada se o menor privilégio for obrigatório.

### Observações

- `*/delete` **não** é necessário: o deploy usa modo incremental (padrão) e não apaga recursos.
- Se algum step falhar com `AuthorizationFailed`, compare a ação exata citada no erro com a lista acima e acrescente apenas o que faltar em `Actions`.

## Fluxo (steps do workflow)

| # | Step                          | O que faz                                                              |
| - | ----------------------------- | ---------------------------------------------------------------------- |
| 1 | Checkout                      | `actions/checkout@v4`                                                  |
| 2 | Login Azure                   | `azure/login@v2` com `creds` (`AZURE_CREDENTIALS`)                    |
| 3 | Resolver nomes                | Composite action: lowercase/regex, valida ambiente/região, monta RG e prefixos, calcula `max+1` → mesmo `NNN` para os dois recursos |
| 4 | Deploy Bicep                  | `azure/bicep-deploy@v2`, escopo subscription, `create` ou `whatIf` (`dry_run`) — cria RG + LAW + App Insights declarativamente |
| 5 | Resumo                        | Tabela no `$GITHUB_STEP_SUMMARY` (`always()`)                          |

## Infraestrutura (Bicep)

`infra/deploy.bicep` (`targetScope = 'subscription'`):

- cria o **Resource Group**;
- orquestra os módulos `infra/modules/log-analytics.bicep` e `infra/modules/app-insights.bicep` no RG;
- o App Insights recebe o `WorkspaceResourceId` do LAW (modelo *workspace-based*), com dependência implícita via output do módulo;
- expõe `rgName`, `logName`, `appiName` e `connectionString`.

Parâmetros do workspace: SKU `PerGB2018` (pay-as-you-go), retenção de 30 dias.

## Próximas melhorias (sugestões)

- **Deployment Stacks** (`type: deploymentStack` + deny-settings) para garantir que ninguém altere os recursos fora do pipeline.
- **OIDC federado** no lugar do client secret (suportado por `azure/login@v2`; exige configurar *federated identity credential*).
- **Ambiente via GitHub Environment** (`environment: dev|homolog|prod`) com secrets e proteções por ambiente.
- **Validação estática** (workflow de PR com `az bicep build` / lint) antes do deploy.
- **Parâmetros extras** (tags de custo/owner, retention configurável por ambiente) propagados via inputs e módulos.
