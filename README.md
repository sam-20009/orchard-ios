# Aether XR — iOS experimental

Projeto independente em **SwiftUI + SceneKit + CoreMotion + Vision**, inspirado no catálogo de funções do [PhoneXR](https://github.com/samrat1games/phonexr). Não é uma redistribuição de seu código: interface e implementação foram escritas independentemente.

## Recursos implementados

- Launcher em português com identidade Aether XR, tema escuro e biblioteca de pacotes.
- Visor 3D estereoscópico **experimental** para VR Box, com câmera por olho e ajuste de IPD.
- Orientação de cabeça por giroscópio (CoreMotion), recentralização e controle de sensibilidade.
- Demonstração de mãos com câmera traseira e Vision (até duas mãos), sem transmissão externa.
- Inspeção local de arquivos `.apk`, `.ipa`, `.pxr`, `.zip`, lista de dependências OpenXR e salvamento no dispositivo.
- Menu de configurações de visor, biblioteca e conforto.

## Limitações que não devem ser ocultadas

Este aplicativo **não executa APKs** no iPhone, não instala nem inicia jogos de outros desenvolvedores e não implementa um runtime OpenXR completo. A visualização do giroscópio pode exigir ajuste fino da orientação conforme o encaixe físico no visor. O rastreamento de mãos é um demonstrador 2D, não um controlador 6DoF. A renderização atual não possui perfil de distorção calibrado para as lentes do VR Box.

## Compilação

Requer macOS com Xcode. O projeto `.xcodeproj` já está incluído: abra-o no Xcode e selecione um *Team* em **Signing & Capabilities** para assinar o aplicativo. Alternativamente, use:

```sh
xcodebuild -project AetherXR.xcodeproj -scheme AetherXR -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Para conferir o analisador em Linux ou macOS com Swift: `./scripts/run-tests.sh`.

O workflow `.github/workflows/ios-build.yml` compila um **IPA sem assinatura** no GitHub Actions. Para instalar no seu iPhone, o app precisa ser assinado com uma identidade de desenvolvedor adequada, conforme as regras do iOS e o método de instalação escolhido. O artefato só existe se o workflow concluir com sucesso.

## Origem e licença

Código Aether XR: MIT (ver LICENSE). PhoneXR é uma referência conceitual externa; licenças, marcas e componentes de terceiros permanecem com os respectivos titulares. Não copie código ou ícones do upstream sem conferir sua licença.
