# PitCrew

**Revisão para o Windows 10 e 11. Toda mudança pode ser desfeita.**

[English](README.md)

O PitCrew é uma ferramenta gratuita e de código aberto para cuidar do Windows: ajustes de
privacidade e desempenho, limpeza de disco, remoção de apps de fábrica e atualização de drivers
pelo Windows Update, tudo numa janela só.

![PitCrew](docs/screenshot-pt-BR.png)

## Princípios

- **Só efeito real.** Cada ajuste tem efeito documentado e aponta para a fonte, normalmente o
  Microsoft Learn. "Otimizações" populares que não mudam nada, ou que enfraquecem a segurança,
  ficam de fora de propósito: veja [docs/NOT-INCLUDED.md](docs/NOT-INCLUDED.md).
- **Tudo pode ser desfeito.** Antes de mudar algo, o PitCrew anota exatamente o que havia (inclusive
  "esse valor não existia"). O Desfazer devolve isso e não mexe no que você mesmo mudou depois.
  Um ponto de restauração é criado antes de cada leva de mudanças.
- **Nada vem marcado.** Você vê o estado atual de cada item e escolhe o que mudar.
- **Linguagem simples.** Cada item diz o que faz e o que você perde.
- **Sem telemetria, sem anúncios, sem baixar código desconhecido.**

## O que faz

| Área | O que faz |
|---|---|
| Desempenho | Planos de energia (PC de mesa), hibernação e Inicialização Rápida, gravação de jogos, aceleração do mouse, jogos em janela, agendamento de GPU, apps em segundo plano e mais |
| Privacidade | Dados de diagnóstico, serviço e tarefas de telemetria, anúncios e sugestões, Copilot, Recall, Widgets, localização, coleta de dados do Edge/Firefox/Brave e mais |
| Explorer e barra de tarefas | Extensões de arquivo, menu de contexto clássico, alinhamento e botões da barra, Finalizar tarefa, modo escuro e mais |
| Inicialização | Ligar ou desligar os programas que abrem com o Windows, do mesmo jeito que o Gerenciador de Tarefas |
| Predefinições e perfis | "Essencial", "Jogos" e "Mais privacidade" só marcam os itens para você conferir; exporte o que está aplicado num PC e importe em outro |
| Limpeza | Temporários, downloads do Windows Update, cache da Otimização de Entrega, relatórios de erro, despejos de travamento e Lixeira, mostrando o tamanho antes |
| Manutenção | Reparar arquivos do sistema (DISM + SFC), remover arquivos antigos de atualizações, saúde dos discos, backup de todos os drivers |
| Apps de fábrica | Remover ou reinstalar 30 apps pré-instalados, cada um marcado "pode remover" ou "leia antes de remover" |
| Drivers | Drivers do Windows Update, conferindo se cada um é mesmo mais novo, com backup dos trocados e link do fabricante da placa-mãe |
| Restauração | Ver os pontos existentes, criar um agora, abrir a Restauração do Sistema; antes de aplicar, o PitCrew oferece criar um (já marcado) |
| Histórico | Tudo o que o PitCrew mudou, com Desfazer |

Cada ajuste e sua fonte estão em [docs/CATALOG.md](docs/CATALOG.md) (gerado a partir do código); o
que vem a seguir está em [docs/TWEAKS.md](docs/TWEAKS.md).

## Como usar

Baixe ou clone o repositório e dê dois cliques em **`PitCrew.bat`**. O Windows pede permissão de
administrador; responda Não para abrir só para ver.

Pelo PowerShell:

```powershell
.\PitCrew.ps1 -List                              # estado de cada ajuste, não muda nada
.\PitCrew.ps1 -Apply privacy.advertising-id      # como administrador
.\PitCrew.ps1 -Undo privacy.advertising-id
```

Logs e o diário de desfazer ficam em `%ProgramData%\PitCrew`.

## Idiomas

Inglês, português (Brasil), espanhol, francês, alemão, russo, turco e chinês simplificado. A janela
segue o idioma do Windows e dá para trocar por ela.

As traduções além de inglês e português foram geradas por máquina. Correções de quem fala esses
idiomas são muito bem-vindas: cada idioma é um arquivo em [`locales/`](locales), e os textos de
cada ajuste ficam junto dele em [`tweaks/`](tweaks).

## Testes

```powershell
powershell -File tests\Run-Tests.ps1     # sem dependências; só mexe numa chave de teste do registro
powershell -File tools\Start-Sandbox.ps1  # testar Aplicar/Desfazer de verdade no Windows Sandbox
```

Veja [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) para entender o motor e como adicionar um ajuste.

## Licença e créditos

MIT. Antes de escrever o PitCrew estudamos outras ferramentas de código aberto; o que aproveitamos
de cada uma e por quê está em [docs/RESEARCH.md](docs/RESEARCH.md). Nenhum código foi copiado de
projetos GPL.
