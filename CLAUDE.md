# Instruções para o Claude

## Antes de qualquer tarefa

1. **Sempre leia o `INDEX.md` primeiro.** Ele mostra o que já foi pesquisado e respondido. Use-o para:
   - evitar repetir uma pesquisa ou pergunta que já existe;
   - complementar um arquivo existente em vez de criar um duplicado;
   - escolher o tema certo para novas perguntas.

## Onde salvar cada resultado

Todo resultado deve ser salvo em arquivo — nunca deixe uma resposta só no chat.

| Tipo de resultado | Pasta | Nome do arquivo |
|---|---|---|
| Pesquisa (tema investigado com fontes) | `pesquisas/` | `AAAA-MM-DD-tema-em-kebab-case.md` (um arquivo por pesquisa) |
| Pergunta e resposta | `perguntas/` | `tema-em-kebab-case.md` (um arquivo por tema; acrescente ao existente) |

- Siga os modelos `pesquisas/_modelo.md` e `perguntas/_modelo.md`.
- Nomes de arquivo: minúsculas, sem acentos, palavras separadas por hífen.
- Datas no formato `AAAA-MM-DD`.

## Depois de salvar

- **Atualize o `INDEX.md`** com uma nova linha (data, tema, link do arquivo) na tabela correta, mantendo a ordem da mais recente para a mais antiga.
- Se uma pergunta for adicionada a um tema que já existe, atualize a data e a contagem da linha desse tema em vez de criar uma linha nova.

## Comandos disponíveis

- `/nova-pesquisa <tema>` — ver `.claude/commands/nova-pesquisa.md`.
- `/nova-pergunta <pergunta>` — ver `.claude/commands/nova-pergunta.md`.
