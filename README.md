# azure

Monorepo de **Infraestrutura as Code** de todo o ambiente Azure — Bicep + CI/CD com **Gitea Actions** e as **actions oficiais da Microsoft**.

## Princípios

- **Um repo para tudo**: cada recurso/tipo de serviço Azure vive aqui como código.
- **Um tipo de projeto por pasta** em `projects/<tipo>/`, sempre com `README.md` próprio (o que provisiona, convenções, RBAC e uso).
- **Workflows finos**: `.gitea/workflows/*.yml` só orquestram (checkout → login → resolver → deploy → resumo); a lógica fica em `actions/` dentro de cada projeto.
- **Actions oficiais** da Microsoft para login e deploy (`azure/login@v2`, `azure/bicep-deploy@v2`) — sem `az login`/`az deployment` embutidos em bash.
- **Imagem de job compartilhada** `artcomp/azure-cli-node` (Azure CLI + Node 24 + git), construída a partir de `docker/azure-cli-node/Dockerfile`.
- **Validação automática**: todo push/PR compila todos os `.bicep` do repo (`validate-bicep.yml`).

## Mapa do repositório

```
azure/
├── README.md                          # este arquivo (visão global e convenções)
├── .gitea/
│   └── workflows/
│       ├── validate-bicep.yml         # CI: compila todos os .bicep (push/PR)
│       └── deploy-app-insights.yml    # deploy do projeto app-insights
├── docker/
│   └── azure-cli-node/
│       └── Dockerfile                 # imagem de job compartilhada (az + node24 + git)
└── projects/
    └── app-insights/
        ├── README.md                  # docs do projeto (inputs, naming, RBAC, fluxo)
        ├── actions/
        │   └── resolve-appi-names/    # composite action: validação + nomes + contador NNN
        └── bicep/
            ├── deploy.bicep           # targetScope = subscription (cria RG + módulos)
            └── modules/
                ├── log-analytics.bicep
                └── app-insights.bicep
```

## Índice de projetos

| Tipo de projeto          | Pasta                        | Workflow                   | Descrição                                              |
| ------------------------ | ---------------------------- | -------------------------- | ------------------------------------------------------ |
| Observabilidade / App Insights | [`projects/app-insights/`](projects/app-insights/README.md) | `deploy-app-insights.yml` | Log Analytics Workspace + Application Insights (workspace-based) com contador `NNN` |

> Ao adicionar um projeto, registre-o nesta tabela (checklist abaixo).

## Convenções globais

### Ambientes e regiões

| Conceito    | Valores                          |
| ----------- | -------------------------------- |
| Ambientes   | `dev`, `homolog`, `prod`         |
| Regiões     | `eastus`, `eastus2`, `brazilsouth` |

### Padrão de nomenclatura de recursos

```
<ambiente>-<tipo>-<app>[-<regiao>-<NNN>]
```

- O **prefixo do ambiente é uniforme** no recurso (`dev` / `homolog` / `prod`).
- O detalhe (`tipo` exato, uso de região e contador) é definido por cada projeto no seu README — ex.: o app-insights usa `-log-`/`-appi-` + contador `NNN` compartilhado entre os pares.

### Segredos globais (repo → Settings → Secrets e variáveis → Actions)

| Secret                  | Descrição                                                     |
| ----------------------- | ------------------------------------------------------------- |
| `AZURE_CREDENTIALS`     | JSON do service principal usado por **todos** os workflows     |
| `AZURE_SUBSCRIPTION_ID` | Subscription de destino (referenciado pelas actions de deploy) |

Formato do `AZURE_CREDENTIALS`:

```json
{
  "clientId": "<APPLICATION_CLIENT_ID>",
  "clientSecret": "<CLIENT_SECRET>",
  "tenantId": "<TENANT_ID>",
  "subscriptionId": "<SUBSCRIPTION_ID>"
}
```

Gerando o service principal:

```bash
az ad sp create-for-rbac \
  --name "sp-azure-monorepo" \
  --role "<ROLE_DO_PROJETO>" \
  --scopes /subscriptions/<SUBSCRIPTION_ID> \
  --json-auth true
```

> `--json-auth true` já emite o JSON no formato do secret (compatível com `azure/login`); `--sdk-auth` é o nome antigo e está deprecado. Sem a flag, monte manualmente: `clientId` ← `appId`, `clientSecret` ← `password`, `tenantId` ← `tenant`.

Conceda ao SP apenas a role documentada no README de cada projeto (uma role por tipo de projeto — ver [RBAC](#rbac-por-projeto)). Projetos futuros podem precisar de secrets adicionais; crie-os no escopo do projeto e documente no README dele.

### Runner e imagem do job

O workflow usa a label `ubuntu-latest`; o runner precisa declará-la:

```yaml
labels:
  - "ubuntu-latest:docker://docker.gitea.com/runner-images:ubuntu-latest"
```

Os jobs sobrescrevem a imagem com `container.image: artcomp/azure-cli-node:latest` (a label só enfileira o job). A imagem precisa de **Azure CLI + Node.js 24 + git** — as actions oficiais são Node24 e usam `az` por dentro; nenhuma imagem pública traz os dois:

```bash
docker build -t artcomp/azure-cli-node:latest -f docker/azure-cli-node/Dockerfile .
docker push artcomp/azure-cli-node:latest
```

| Registro                  | Como referenciar                                 | Observação                                                     |
| ------------------------- | ------------------------------------------------ | -------------------------------------------------------------- |
| Docker Hub (público)      | `artcomp/azure-cli-node:latest`                  | Runner puxa anonimamente — mais simples                        |
| Package registry do Gitea | `<host-do-gitea>/<usuario>/azure-cli-node:latest`| Requer pacotes habilitados no Gitea e `docker login <host>` no **host** do runner |

Para outra tag/registro, ajuste `container.image` em todos os workflows.

### CI (validação)

[`.gitea/workflows/validate-bicep.yml`](.gitea/workflows/validate-bicep.yml) roda em **push, pull request e manualmente**, compila com `az bicep build` **todos** os `.bicep` de `projects/` e falha em qualquer erro de template. Novos projetos entram na validação automaticamente.

### RBAC por projeto

- Cada tipo de projeto define a **própria role mínima** no seu README (JSON + `az role definition create` + `az role assignment create`).
- Regra geral: **não** use `Contributor` por padrão; não inclua `*/delete`; `AssignableScopes` na subscription quando o deploy cria o RG (escopo subscription).
- Em caso de `AuthorizationFailed`, acrescente ao `Actions` apenas a ação exata citada no erro.

## Como adicionar um novo tipo de projeto (checklist)

1. Crie `projects/<tipo>/` com **`README.md` obrigatório**: o que provisiona, inputs/naming, RBAC mínimo, uso e outputs.
2. Organize o código: `bicep/` (`deploy.bicep` + `modules/`) e, se houver lógica imperativa (nomes, contadores, pré-checagens), isole-a em uma composite action em `actions/` — nada de lógica embutida no workflow.
3. Crie a **role RBAC mínima** do projeto e documente o JSON + comandos no README dele.
4. Adicione um workflow fino em `.gitea/workflows/deploy-<tipo>.yml` seguindo o padrão dos 5 steps — copie [`deploy-app-insights.yml`](.gitea/workflows/deploy-app-insights.yml) como referência.
5. Registre o projeto na [índice de projetos](#índice-de-projetos).
6. Confirme que a validação cobre o novo diretório (ela varre `projects/**/*.bicep` — já coberto).
7. Secrets: use os globais; crie secrets novos só se o projeto precisar de mais credenciais e documente-os no README do projeto.

## Pontos de atenção

- **Modo de deploy**: incremental (nenhuma ação de delete no RBAC).
- **Concorrência**: cada workflow define um `concurrency` group próprio para não disputar contadores/estado.
- **`workflow_dispatch` só aparece na branch padrão** do repositório.
- **Saídas sensíveis** (ex.: `connectionString`) devem ser mascaradas na action de deploy (`masked-outputs`).
