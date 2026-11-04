<img src="assets/pitcrew.png" alt="Ícone do PitCrew" width="96">

# PitCrew

**Revisão para o Windows 10 e 11. Toda mudança pode ser desfeita.**

[English](README.md)

> **Beta (0.1.0).** Esta é a primeira versão pública. Deixe marcada a opção de ponto de
> restauração ao aplicar e conte o que der errado em [Issues](https://github.com/jothank/pitcrew/issues).

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
  Antes de aplicar, o PitCrew oferece criar um ponto de restauração (já marcado).
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
| Memória | Quanto da RAM está em uso e quais programas usam mais, com um jeito educado de fechá-los (como clicar no X); agenda o teste de memória do próprio Windows. Sem "limpador de RAM": veja o motivo em [docs/NOT-INCLUDED.md](docs/NOT-INCLUDED.md) |
| Manutenção | Reparar arquivos do sistema (DISM + SFC), remover arquivos antigos de atualizações, otimizar unidades (TRIM no SSD, desfragmentação no HD), procurar erros nas unidades (só leitura), saúde dos discos, limpar o cache de DNS, backup de todos os drivers |
| Apps de fábrica | Remover ou reinstalar 30 apps pré-instalados, cada um marcado "pode remover" ou "leia antes de remover" |
| Drivers | Drivers do Windows Update, conferindo se cada um é mesmo mais novo, com backup dos trocados e link do fabricante da placa-mãe |
| Restauração | Ver os pontos existentes, criar um agora, abrir a Restauração do Sistema; antes de aplicar, o PitCrew oferece criar um (já marcado) |
| Histórico | Tudo o que o PitCrew mudou, com Desfazer |

Cada ajuste e sua fonte estão em [docs/CATALOG.md](docs/CATALOG.md) (gerado a partir do código); o
que vem a seguir está em [docs/TWEAKS.md](docs/TWEAKS.md).

## Baixar e usar

1. Baixe o `PitCrew-0.1.0-beta.zip` em [Releases](https://github.com/jothank/pitcrew/releases).
2. Clique com o botão direito no zip, escolha **Extrair tudo...** e depois **Extrair**.
3. Na pasta que abrir, entre na pasta **PitCrew** e dê dois cliques em **`PitCrew.exe`**.
4. O Windows pede permissão de administrador. Responda **Sim** para fazer mudanças, ou **Não**
   para só olhar (modo somente leitura).

Nada é instalado: o PitCrew roda a partir dessa pasta.

**Apareceu "O Windows protegeu o computador"?** O PitCrew ainda não tem assinatura digital, então o
SmartScreen avisa como faz com qualquer programa novo de editor desconhecido. Clique em **Mais
informações** e depois em **Executar assim mesmo**. Dá para conferir o download antes: o SHA-256
do zip fica publicado ao lado dele, e o `PitCrew.exe` é só um lançador pequeno, com o código em
[`tools/launcher/PitCrew.cs`](tools/launcher/PitCrew.cs).

**Bloqueado pelo Controle Inteligente de Aplicativos ou pelo antivírus?** O Controle Inteligente de
Aplicativos (Smart App Control, do Windows 11) pode bloquear programas sem assinatura, sem a opção
"executar assim mesmo". Use então o **`PitCrew.bat`** da mesma pasta: ele faz a mesma coisa. Não
desligue esse controle por causa do PitCrew: em muitas versões do Windows ele só volta reinstalando
o sistema. Uma versão assinada está nos planos.

Pelo PowerShell:

```powershell
.\PitCrew.ps1 -List                              # estado de cada ajuste, não muda nada
.\PitCrew.ps1 -Apply privacy.advertising-id      # como administrador
.\PitCrew.ps1 -Undo privacy.advertising-id
```

Logs e o diário de desfazer ficam em `%ProgramData%\PitCrew`.

## Remover o PitCrew

Primeiro abra o **Histórico** e desfaça o que quiser que volte a ser como era: o PitCrew só
consegue desfazer as mudanças dele enquanto o diário de desfazer existir. Depois apague a pasta do
PitCrew. O diário e os logs ficam em `C:\ProgramData\PitCrew`; apague essa pasta por último, se
quiser.

## Idiomas

Inglês, português (Brasil), espanhol, francês, alemão, russo, turco e chinês simplificado. A janela
segue o idioma do Windows (um Windows argentino abre em espanhol, um brasileiro em português) e,
sem idioma compatível, abre em inglês. O idioma escolhido na janela fica guardado. Os temas claro e
escuro também seguem o Windows ou podem ser escolhidos na janela. As listas têm filtro por estado
(aplicados, não aplicados, instalados...) e dá para marcar tudo o que está na tela num clique.

As traduções além de inglês e português foram geradas por máquina. Correções de quem fala esses
idiomas são muito bem-vindas: cada idioma é um arquivo em [`locales/`](locales), e os textos de
cada ajuste ficam junto dele em [`tweaks/`](tweaks).

## Testes e versão para download

```powershell
powershell -File tests\Run-Tests.ps1         # sem dependências; só mexe numa chave de teste do registro
powershell -File tools\Start-Sandbox.ps1      # testar Aplicar/Desfazer de verdade no Windows Sandbox
powershell -File tools\Build-Release.ps1      # testes e depois dist\PitCrew-<versão>.zip a partir do último commit
powershell -STA -File tools\Build-Icon.ps1    # redesenha assets\pitcrew.ico e .png a partir do código
```

A versão para download não precisa de nada além do Windows: o `PitCrew.exe` é compilado com o
compilador C# que vem com o .NET Framework, e o zip sai de um commit pelo `git archive` (o `-Dev`
gera um zip de teste com mudanças ainda sem commit).

Veja [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) para entender o motor e como adicionar um ajuste.
As mudanças de cada versão estão no [CHANGELOG.md](CHANGELOG.md); para relatar um problema de
segurança, veja o [SECURITY.md](SECURITY.md).

## Apoie o projeto

O PitCrew é gratuito e sempre vai ser. Se ele te ajudou, dá para apoiar com qualquer valor pelo
Pix: aponte a câmera do app do banco para o código ou use a chave abaixo. O mesmo código está na
tela Sobre.

<img src="assets/pix-qr.png" alt="QR Code do Pix" width="180">

Chave Pix: `7405c643-a1be-43dc-97f3-ee468160668a`

## Autor

Feito por **Jonathan Costa**, engenheiro de dados:
[GitHub](https://github.com/jothank) · [LinkedIn](https://www.linkedin.com/in/jothank/).
O PitCrew começou como um pequeno script para atualizar os drivers do meu PC e foi crescendo.

## Licença e créditos

MIT © 2026 Jonathan Costa. Antes de escrever o PitCrew estudamos outras ferramentas de código
aberto; o que aproveitamos de cada uma e por quê está em [docs/RESEARCH.md](docs/RESEARCH.md).
Nenhum código foi copiado de projetos GPL.
