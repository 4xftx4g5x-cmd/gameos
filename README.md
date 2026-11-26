# HKOS (HK Tech)

Sistema Linux (base Arch) extremamente leve, todo preto, feito para jogos: FPS alto e latência baixa.
Vem com Steam, Discord, Firefox, Heroic, drivers e ferramentas de desempenho.

## Como gerar a ISO

1. Suba para o repositório (arquivos soltos na raiz): `build.sh`, `packages.extra`, `wallpaper.png`, `boot-splash.png`, `README.md`.
2. O arquivo `.github/workflows/build-iso.yml` fica na pasta `.github/workflows/` (criado pelo site do GitHub).
3. Aba **Actions** > **Build GameOS ISO** > **Run workflow**.
   - Marque `kernel_v3` só se a sua CPU tiver AVX2 (Intel 2013+ ou AMD Ryzen). Em CPU mais antiga o sistema não inicia.
4. Quando terminar, baixe o artefato `gameos-iso` (a ISO e o `SHA256SUMS`).
5. Grave a ISO em um pendrive (Rufus no modo DD, ou balenaEtcher).

O primeiro build compila o kernel próprio (`linux-hkos`) e pode levar de 1h30 a 3h. Os seguintes usam o cache e levam uns 20 minutos.
Para recompilar o kernel, troque `KERNEL_REV` no arquivo do workflow.
Se a compilação falhar, o HKOS usa o `linux-zen` e a ISO sai do mesmo jeito.

## Testes automáticos

Cada build confere se a ISO tem o kernel, o instalador, o Steam, o Firefox, o Discord e as ferramentas do HKOS, e tenta dar boot no QEMU (o boot é só informativo).

## Instalar no disco

No sistema live, abra o terminal e rode `hkos-install`.
- UEFI usa systemd-boot e BIOS usa GRUB.
- Particionamento automático (apaga o disco) ou manual (cfdisk).
- Criptografia LUKS opcional (use só letras e números na senha).
- Sistema de arquivos: ext4, xfs ou f2fs. Firmware só do seu hardware ou completo.
- Dual boot não é suportado.

## Comandos do HKOS

| Comando | Para que serve |
|---|---|
| `hkos-control` | Painel central com tudo |
| `hkos-game` | Roda o jogo com ajustes de FPS e latência (Steam: `hkos-game %command%`) |
| `hkos-bench` | Mede FPS médio, 1% low e 0,1% low |
| `hkos-gpu` | Energia, clock e overclock da placa de vídeo |
| `hkos-fan` | Ventoinha da placa de vídeo |
| `hkos-mode` | `desktop`, `console` ou `ultra` |
| `hkos-update` | Atualiza com foto de segurança; `hkos-update rollback` volta atrás |
| `hkos-loja` | Programas, drivers e Flatpak |
| `hkos-proton-ge` | Baixa o Proton-HKOS (padrão), `ge` ou `cachyos` |
| `hkos-heroic` | Heroic Games Launcher (Epic, GOG, Amazon) |
| `hkos-info` | Relatório do sistema |
| `hkos-ajuda` | Ajuda e atalhos |

Atalhos: Windows+E explorador, Windows+R executar, Ctrl+Esc menu Iniciar, botão direito na área de trabalho abre o menu.

## Como medir se melhorou

Rode o mesmo jogo, na mesma cena, com `hkos-bench -t 120 %command%` (Steam > Opções de inicialização) e compare com `hkos-bench compare`.
Faça isso com o kernel `linux-zen` e com o `linux-hkos`, e com Proton-GE, CachyOS e HKOS.

## Repositório de pacotes

O build publica o kernel no release `repo` do GitHub. O sistema instalado usa esse repositório para atualizar o kernel junto com o `pacman -Syu`.

## Limitações

- Só foi testado em um PC (GTX 1660 Super). Se der problema no seu hardware, me conte.
- O ganho do kernel próprio é pequeno (1–3%). Meça antes de confiar.
- Pacotes do sistema não são recompilados em x86-64-v3.
