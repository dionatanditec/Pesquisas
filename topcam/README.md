# TopCam

Câmera profissional para iPhone, para qualquer nicho: pessoas, lugares, ambientes, objetos, comida e noite. Uso pessoal (não vai para a App Store).

## O que a versão 1.0 faz

- **Foto** em HEIF com o look aplicado, e RAW/ProRAW opcional (salva os dois).
- **9 looks** com intensidade de 0 a 100%: Original, Natural, Vivo, Retrato, Paisagem, Produto, Comida, Noite, P&B.
- **Look automático pela cena**: reconhece pessoa, paisagem, objeto, animal, ambiente, comida e pouca luz, e escolhe o look.
- **Vídeo** em 4K 30 HEVC (≈190 MB/min) ou 1080p (≈60 MB/min), já gravado com o look, com estabilização.
- **Proteção de espaço**: mostra quantos minutos cabem, baixa para 1080p com pouco espaço e para sozinho antes de lotar.
- **Modo Pro**: ISO, velocidade, balanço de branco, foco manual e EV, com botão AUTO.
- **Lentes** 0,5 / 1× / Tele (conforme o iPhone) e câmera da frente.
- **Toque para focar**, **linhas de grade** (liga/desliga) e **nível** (fica verde quando reto; mostra "Vista de cima" na foto de cima).

## Como gerar o arquivo de instalação (.ipa)

O GitHub compila o app num Mac na nuvem, de graça (repositório público).

1. Suba esta pasta para `github.com/dionatanditec/topcam` (branch `main`).
2. A cada envio, a aba **Actions** roda o **Build iOS** sozinha (ou clique em **Run workflow**).
3. Quando ficar verde, abra a execução e baixe **TopCam-ipa** (vem em .zip; dentro está o `TopCam.ipa`).

## Como instalar no iPhone (Windows)

1. Instale o **iTunes** do site da Apple (não o da Microsoft Store) e o **Sideloadly** (sideloadly.io).
2. No iPhone: **Ajustes → Privacidade e Segurança → Modo de Desenvolvedor → ativar** (reinicia).
3. Ligue o iPhone no cabo, abra o Sideloadly, coloque seu Apple ID, arraste o `TopCam.ipa` e clique **Start**.
4. No iPhone: **Ajustes → Geral → VPN e Gerenciamento de Dispositivos → seu Apple ID → Confiar**.
5. Com Apple ID grátis, o app vale **7 dias**. Depois é só repetir o passo 3 (não apague o app antes).

## Passar fotos e vídeos para o computador

- **LocalSend** (grátis, pelo Wi-Fi): instale no iPhone e no PC, mesma rede, selecione e envie.
- **Cabo**: app **Fotos** do Windows → **Importar**.
- Para assistir no Windows: **VLC**. Para editar: **DaVinci Resolve** (grátis).

## Próximas versões (pedir ao Claude Code)

- v2: cor seletiva (HSL), fundo desfocado, perfis de marca salvos (look + logo), histograma.
- v3: importar LUTs .cube, Apple Log com look por cima, Modo Cinema, zebra e realce de foco, câmera lenta e time-lapse.
- v4: editor com antes/depois, exportar 9:16/1:1/4:5, enviar para o PC pelo Wi-Fi, ProRes.

## Estrutura

- `project.yml` – projeto (XcodeGen gera o `.xcodeproj` na nuvem)
- `TopCam/CameraModel.swift` – câmera, foto, vídeo, modo Pro
- `TopCam/Looks.swift` – os looks (filtros)
- `TopCam/ContentView.swift` – telas
- `TopCam/VideoRecorder.swift` – gravação com o look
- `TopCam/MetalPreview.swift` – visor em tempo real
- `TopCam/Support.swift` – galeria, nível, detecção de cena, espaço
- `.github/workflows/ios-build.yml` – robô que gera o `.ipa`
