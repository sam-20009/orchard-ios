# Relatório de testes — Aether XR 0.1.0

Data: 07/11/2026. Ambiente: Linux x86_64, Swift 6.2.1, sem Xcode/iOS SDK e sem iPhone conectado.

| Componente | Verificação | Resultado |
|---|---|---|
| APK Android | ZIP com AndroidManifest e libopenxr_loader.so | PASSOU |
| IPA | Estrutura Payload/Test.app | PASSOU |
| PXR | manifesto, payload Android e iOS | PASSOU |
| ZIP | Arquivo ZIP genérico | PASSOU |
| Arquivo inválido | Rejeição da entrada | PASSOU |
| Sintaxe Swift | `swiftc -frontend -parse AetherXR/*.swift` | PASSOU |
| Projeto Xcode | `plutil -lint` do arquivo project.pbxproj | PASSOU |
| Info.plist | `plutil -lint` | PASSOU |
| Cena VR | Teste em hardware / fluidez / distorção | NÃO TESTADO |
| CoreMotion | Orientação e inversão no VR Box | NÃO TESTADO |
| Câmera / Vision | Permissões, precisão e FPS | NÃO TESTADO |
| Build/IPA iOS | Xcode para SDK iOS / assinatura | NÃO REALIZADO |
| Jogos Android | Execução de APK no iOS | NÃO IMPLEMENTADO |

**Importante:** testes locais não demonstram que o aplicativo compila ou roda no iPhone. O visor é um ambiente nativo de demonstração, não um runtime OpenXR universal.

Para repetir os testes: `./scripts/run-tests.sh`.
