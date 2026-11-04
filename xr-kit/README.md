# Samuel VR Box — versão experimental

Base Android: [Husk 3.2.1](https://github.com/Leviidev/Husk/releases/tag/3.2.1), GPL-2.0-or-later. Este projeto baixa o código correspondente e verifica o SHA-256 do IPA oficial antes de reutilizar as dependências da mesma versão. Preserva o assistente, o serviço auxiliar de JIT, a biblioteca Android e os créditos originais.

## Usar no iPhone

1. Gere **Samuel-VRBox.ipa** pelo GitHub Actions ou, em um Mac com Xcode e SDK do iPhone, rode `bash tools/build_ipa.sh`. O fluxo ad-hoc gera um arquivo para reassinar com seu perfil de desenvolvimento. Mantenha a extensão **HuskJITHelper** durante a instalação.
2. Abra **Settings → JIT & sideload → Set up JIT**. Escolha **Use a pairing file** e selecione o arquivo no iPhone. Em iOS 27, o assistente também oferece o pareamento no próprio telefone. O arquivo fica no dispositivo. Use o LocalDevVPN e complete a verificação do Developer Disk Image quando o assistente pedir.
3. Toque em **Enable JIT** no primeiro ajuste. Depois do pareamento, o app tenta ativar JIT na abertura usando o assistente embutido. O sistema precisa permitir a depuração no perfil de assinatura.
4. Abra a aba **VR Box**. Ajuste a distância entre os olhos e a distância do painel. Deixe a câmera traseira livre e abra o visor. A pinça no fundo move o painel. A pinça no canto verde muda seu tamanho. Botões são ativados ao soltar a pinça sobre o mesmo alvo. O painel tem atalhos para alternar modos, centralizar, desfazer, consultar a ajuda, abrir a biblioteca ou sair. Com controle Bluetooth, **Y** alterna entre mãos e controle, **A** confirma ou segura, **X** muda a ação, **B** recentraliza, **LB** alterna a câmera, **RB** oculta ou mostra o painel e **Menu** fecha.
5. Volte à biblioteca para importar os seus apps Android. A bancada nativa e a biblioteca Android são separadas. A bancada tem visão para os dois olhos e rastreamento ARKit, sem correção óptica específica para modelos de lente.

## Visão do ambiente

A câmera traseira abre automaticamente por padrão e o painel acompanha a cabeça. O botão **Câmera** ou **LB** alterna o vídeo. Segure a palma aberta diante da câmera por cerca de um segundo ou pressione **RB** para alternar entre painel e só o ambiente. Abaixe ou feche a mão antes de repetir o gesto. Também é possível tocar na tela para restaurar o painel.

O visor espera uma imagem ao vivo antes de esconder o painel. Se o vídeo para, a imagem antiga é descartada e o painel reaparece. O vídeo fica no iPhone.

A imagem da câmera é monocular e aparece nos dois olhos. Ela não substitui visão periférica, percepção de profundidade ou detecção de obstáculos. Teste o visor parado, de preferência sentado.

## Conforto e recuperação

A posição sentada, o contraste, o tamanho do texto, as distâncias e o modo leve ficam salvos no iPhone. O modo leve apresenta cada olho a 30 fps e limita o reconhecimento de mãos. Em caso de rastreamento limitado ou câmera interrompida, o visor indica o motivo e cancela a ação em andamento para evitar seleções acidentais. O visor também respeita a preferência **Reduzir Movimento** do iOS para esconder a grade de referência.

## Imagens do Android

O modo VM do Husk baixa a [imagem LineageOS ARM64 v12](https://github.com/Leviidev/Husk/releases/download/lineage-v2/vda-v12.qcow2) no próprio app. Ela tem 2.057.568.256 bytes. SHA-256 `a8dbaecc8fdcd682991b078d6bbb7df6972e459208634fa8dcbad24f17208d6a`. O download automático do snapshot de 4 GiB de RAM fica desligado por padrão neste perfil. A escolha de memória adaptativa do Husk permanece ativa.

A [imagem Android XR ARM64 oficial do Google](https://dl.google.com/android/repository/sys-img/google_xr/xr-preview-arm64-v8a-playstore-34_r04.zip) é um AVD de desenvolvimento para o Android Studio. O Google informa que seu emulador não suporta OpenXR nem Unity. Ela não é o sistema do Quest e não serve como imagem de instalação para rodar Roblox VR neste app.

## Verificar um APK

```sh
python3 tools/check_xr_package.py caminho/arquivo.apk
```

A ferramenta inspeciona ARM64, bibliotecas gráficas e indícios de OpenXR em APK/APKS/XAPK. A presença dessas bibliotecas só indica o que o app pode exigir.

O cliente Roblox VR precisa de um runtime OpenXR que receba os quadros de cada olho e envie poses e comandos ao jogo. Esse runtime e o suporte ao Roblox no iPhone ainda precisam ser implementados e testados. Os controles da bancada funcionam sobre o painel nativo.
