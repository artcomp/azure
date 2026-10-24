# Application Insights + Log Analytics

> **Tipo de projeto:** observabilidade · **Workflow:** [`.gitea/workflows/deploy-app-insights.yml`](../../.gitea/workflows/deploy-app-insights.yml)

Provisiona um **Log Analytics Workspace** e um **Azure Application Insights** (workspace-based) via Bicep, com actions oficiais da Microsoft (`azure/login@v2`, `azure/bicep-deploy@v2`) — sem bash embutido de login/deploy e sem template gerado inline.

> O Application Insights moderno (workspace-based) **exige** um Log Analytics Workspace — por isso o deploy cria os dois juntos, no mesmo Resource Group e na mesma região.

**Depende dos pré-requisitos globais** (imagem do job, runner e secrets `AZURE_CREDENTIALS`/`AZURE_SUBSCRIPTION_ID`): ver [README global](../../README.md).

## Arquitetura

```
workflow_dispatch (app_name, environment, region, dry_run)
        │
        ▼
┌─ job: deploy  (container: artcomp/azure-cli-node:latest → az + node24 + git) ─┐
│  1. actions/checkout@v4                                                       │
│  2. azure/login@v2                (SP via secret AZURE_CREDENTIALS)           │
│  3. ./projects/app-insights/actions/resolve-appi-names (valida + nomes + NNN) │
│  4. azure/bicep-deploy@v2         (scope: subscription, create|whatIf)        │
│       └─ projects/app-insights/bicep/deploy.bicep → RG + LAW + App Insights   │
│  5. Resumo (step summary, always())                                           │
└───────────────────────────────────────────────────────────────────────────────┘
```

> `azure/arm-deploy` está sendo **descontinuada** pela Microsoft; este fluxo usa o substituto oficial **[`azure/bicep-deploy`](https://github.com/Azure/bicep-deploy)**, feito para Bicep, com suporte a *what-if* e *deployment stacks*.

## Inputs

| Input         | Tipo      | Opções                               | Obrigatório |
| ------------- | --------- | ------------------------------------ | ----------- |
| `app_name`    | `string`  | `a-z`, `0-9`, hífens (2–41 chars)    | Sim         |
| `environment` | `choice`  | `dev`, `homolog`, `prod`             | Sim         |
| `region`      | `choice`  | `eastus`, `eastus2`, `brazilsouth`   | Sim         |
| `dry_run`     | `boolean` | `true` simula (what-if), `false` cria| Não (`false`) |

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

Exemplo com `app_name=meuapp`, `environment=homolog`, `region=brazilsouth`:

```
homolog-rg-meuapp
├── homolog-log-meuapp-brazilsouth-001   ← Log Analytics Workspace
└── homolog-appi-meuapp-brazilsouth-001  ← Application Insights (ligado ao workspace acima)
```

## Fluxo (steps do workflow)

| # | Step                          | O que faz                                                                                                                              |
| - | ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| 1 | Checkout                      | `actions/checkout@v4`                                                                                                                  |
| 2 | Login Azure                   | `azure/login@v2` com `creds` (`AZURE_CREDENTIALS`)                                                                                    |
| 3 | Resolver nomes                | Composite action (`actions/resolve-appi-names`): lowercase/regex, valida ambiente/região, monta RG e prefixos, calcula `max+1` → mesmo `NNN` para os dois recursos |
| 4 | Deploy Bicep                  | `azure/bicep-deploy@v2`, escopo subscription, `create` ou `whatIf` (`dry_run`) — cria RG + LAW + App Insights declarativamente        |
| 5 | Resumo                        | Tabela no `$GITHUB_STEP_SUMMARY` (`always()`)                                                                                          |

### Concorrência

Um `concurrency` group por `ambiente + app_name` com `cancel-in-progress: false` evita duas execuções simultâneas disputando o mesmo contador.

## Infraestrutura (Bicep)

```
projects/app-insights/bicep/
├── deploy.bicep                        # targetScope = subscription
└── modules/
    ├── log-analytics.bicep             # LAW: PerGB2018, retenção 30 dias
    └── app-insights.bicep              # App Insights workspace-based
```

`deploy.bicep`:

- cria o **Resource Group**;
- orquestra os módulos no RG;
- o App Insights recebe o `WorkspaceResourceId` do LAW, com dependência implícita via output do módulo;
- expõe `rgName`, `logName`, `appiName` e `connectionString`.

## Permissões RBAC mínimas

O workflow executa exatamente estas operações ARM:

| Operação                          | Quem executa                     | Ação ARM necessária                                                                                                          |
| --------------------------------- | -------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Verificar existência do RG        | `resolve.sh` (`az group exists`) | `Microsoft.Resources/resourceGroups/read`                                                                                    |
| Listar recursos no RG (contador)  | `resolve.sh` (`az resource list`)| `Microsoft.Resources/resourceGroups/resources/read`                                                                          |
| Criar RG + deployment (sub scope) | `azure/bicep-deploy@v2`          | `Microsoft.Resources/resourceGroups/write` + `Microsoft.Resources/deployments/read` + `Microsoft.Resources/deployments/write` |
| Criar Log Analytics               | módulo Bicep                     | `Microsoft.OperationalInsights/workspaces/read` + `write`                                                                    |
| Criar App Insights                | módulo Bicep                     | `Microsoft.Insights/components/read` + `write`                                                                               |

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

## Uso

1. Push para a branch padrão (o `workflow_dispatch` só aparece na branch padrão).
2. No Gitea: **Ações → Deploy App Insights + Log Analytics (Bicep) → Run workflow** e preencha os inputs.
3. Para **simular sem alterar nada**, marque `dry_run` → o deploy roda em modo *what-if*.
4. Ao final, o **step summary** mostra ambiente, região, modo, RG e os nomes criados.

Outputs do step `deploy` disponíveis para steps/jobs seguintes: `rgName`, `logName`, `appiName` e `connectionString` (mascarado nos logs via `masked-outputs`).

## Próximas melhorias (sugestões)

- **Deployment Stacks** (`type: deploymentStack` + deny-settings) para garantir que ninguém altere os recursos fora do pipeline.
- **OIDC federado** no lugar do client secret (suportado por `azure/login@v2`; exige configurar *federated identity credential*).
- **Ambiente via GitHub Environment** (`environment: dev|homolog|prod`) com secrets e proteções por ambiente.
- **Parâmetros extras** (tags de custo/owner, retention configurável por ambiente) propagados via inputs e módulos.
