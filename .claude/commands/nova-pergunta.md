---
description: Responde uma pergunta, salva em perguntas/ no tema certo e atualiza o INDEX.md
argument-hint: <pergunta>
---

Pergunta: **$ARGUMENTS**

Siga estes passos:

1. **Leia o `INDEX.md`** para ver os temas já existentes em `perguntas/` e se esta pergunta já foi respondida.
2. **Escolha o tema**: use um tema existente se a pergunta se encaixar nele; caso contrário, crie um tema novo, curto e genérico (ex.: `financas`, `programacao`, `saude`).
3. **Responda a pergunta** de forma clara e direta. Se precisar de informação atual ou específica, pesquise na internet e cite as fontes.
4. **Salve em `perguntas/<tema-em-kebab-case>.md`**:
   - se o arquivo existir, acrescente a pergunta no final, seguindo o formato de `perguntas/_modelo.md`;
   - se não existir, crie o arquivo a partir de `perguntas/_modelo.md`.
   Cada entrada deve ter: a pergunta como título, a data (AAAA-MM-DD), a resposta e as fontes (se houver).
5. **Atualize o `INDEX.md`** na tabela "Perguntas por tema":
   - tema novo: adicione uma linha no topo com `| AAAA-MM-DD | <Tema> | 1 | [arquivo](perguntas/<arquivo>.md) |`;
   - tema existente: atualize a data e some 1 ao número de perguntas, movendo a linha para o topo.
6. Mostre a resposta ao usuário e informe em qual arquivo ela foi salva.
