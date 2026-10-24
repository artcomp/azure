# Deploy de Application Insights no Azure (Bicep + Gitea Actions)

Workflow de CI/CD que provisiona um **Azure Application Insights** usando **Bicep**, executado pelo **Gitea Actions** dentro da imagem oficial **`mcr.microsoft.com/azure-cli`**.

Tudo (validação, login, resource group, naming e deploy) vive em **um único workflow**, sem dependências externas além das secrets de Azure.

## Como funciona

1. Você dispara o workflow via `workflow_dispatch` informando **nome da aplicação**, **ambiente** e **região**.
2. O runner sobe o container da imagem oficial do Azure CLI.
3. O workflow valida os inputs, autentica no Azure (service principal), garante que o Resource Group exista, calcula o próximo contador de nome, gera o template Bicep inline e executa o deploy.

## Inputs

| Input        | Tipo     | Opções                              | Obrigatório |
| ------------ | -------- | ----------------------------------- | ----------- |
| `app_name`   | `string` | `a-z`, `0-9`, hífens (2–41 chars)   | Sim         |
| `environment`| `choice` | `dev`, `homolog`, `prod`            | Sim         |
| `region`     | `choice` | `eastus`, `eastus2`, `brazilsouth`  | Sim         |

> `app_name` é normalizado para **lowercase** antes de validar. Ex.: `MeuApp` → `meuapp`.

## Convenção de nomes

| Recurso           | Padrão                                   | Exemplo                                  |
| ----------------- | ---------------------------------------- | ---------------------------------------- |
| Resource Group    | `<ambiente>-rg-<app>`                    | `homolog-rg-meuapp`                      |
| Application Insights | `<ambiente>-appi-<app>-<regiao>-<NNN>` | `homolog-appi-meuapp-brazilsouth-001`    |

- O **contador `NNN`** é sequencial (`001`, `002`, …), calculado a partir do maior sufixo já existente no Resource Group para o mesmo prefixo (`max + 1`).
- Falha com erro se o contador passar de `999`.
- O prefixo usa o valor do ambiente **exatamente como escolhido** (`dev` / `homolog` / `prod`).

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

O service principal precisa de permissão para:
- **criar Resource Groups** na região alvo (ex.: `Contributor` no Management Group/Subscription);
- **criar/deployar** recursos `Microsoft.Insights/components` no RG.

## Uso

1. Copie o arquivo para o seu repositório:

   ```
   .gitea/workflows/deploy-app-insights.yml
   ```

2. Push para a branch padrão (o `workflow_dispatch` só aparece na branch padrão).

3. No Gitea: **Ações → Deploy App Insights (Bicep) → Run workflow** e preencha os 3 inputs.

4. Acompanhe o log. Ao final, um **step summary** mostra ambiente, região, RG e nome do App Insights criado.

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
| 1 | Validar inputs e derivar nomes | Lowercase + regex no `app_name`; valida `environment`/`region`; monta RG e prefixo |
| 2 | Login Azure                    | `az login --service-principal` + `az account set` (falha se secret ausente) |
| 3 | Garantir Resource Group        | `az group exists` → cria com `az group create` se necessário              |
| 4 | Calcular próximo contador      | Lista `Microsoft.Insights/components` no RG, pega `max` do prefixo, soma 1 |
| 5 | Gerar template Bicep           | Grava `infra/main.bicep` inline (heredoc)                                 |
| 6 | Deploy via Bicep               | `az bicep install` + `az deployment group create`                         |
| 7 | Resumo                         | Escreve tabela no `$GITHUB_STEP_SUMMARY` (roda `always()`)                |

### Concorrência

Um `concurrency` group por `ambiente + app_name` com `cancel-in-progress: false` evita duas execuções simultâneas disputando o mesmo contador.

## Template Bicep

```bicep
param name string
param location string

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: name
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
}

output name string = appInsights.name
output connectionString string = appInsights.properties.ConnectionString
```

## Notas

- **Imagem**: `mcr.microsoft.com/azure-cli:latest` (Azure Linux). Para reprodutibilidade, troque por uma tag fixa, ex.: `2.74.0-azurelinux3.0`.
- **Bicep**: instalado no step via `az bicep install` (não vem pré-instalado na imagem).
- **Autenticação**: direto via `az login` no container — não usa a action `azure/login`.
- **Modo de deploy**: incremental (padrão do `az deployment group create`).
