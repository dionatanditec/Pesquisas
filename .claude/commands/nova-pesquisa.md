---
description: Pesquisa um tema na internet, salva o relatório em pesquisas/ e atualiza o INDEX.md
argument-hint: <tema>
---

Tema da pesquisa: **$ARGUMENTS**

Siga estes passos:

1. **Leia o `INDEX.md`** e verifique se já existe uma pesquisa sobre este tema. Se existir, leia o arquivo e foque em complementar o que falta (e diga isso ao usuário) em vez de repetir.
2. **Defina a pergunta** central que a pesquisa deve responder sobre o tema.
3. **Pesquise na internet** com a ferramenta de busca web. Consulte várias fontes confiáveis e atuais; abra as páginas mais relevantes para confirmar os dados. Anote o link de cada fonte usada.
4. **Crie o relatório** em `pesquisas/AAAA-MM-DD-<tema-em-kebab-case>.md` (data de hoje; nome em minúsculas, sem acentos), seguindo `pesquisas/_modelo.md`, com as seções:
   - Data
   - Pergunta
   - Resumo
   - Fontes (com links)
   - Próximos passos
5. **Atualize o `INDEX.md`**: adicione uma linha no topo da tabela "Pesquisas" com `| AAAA-MM-DD | <Tema> | [arquivo](pesquisas/<arquivo>.md) |`.
6. Mostre ao usuário um resumo curto do resultado e o caminho do arquivo criado.
