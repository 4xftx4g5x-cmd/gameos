# GameOS

Sistema Linux otimizado para jogos, baseado em Arch Linux (archiso). Este projeto monta uma ISO live/instalável com KDE Plasma, drivers de vídeo, Steam, Lutris (Battle.net), Discord e Firefox.

> **Status:** projeto inicial, **ainda não testado em hardware nem em VM**. Espere ajustes na primeira build.

## O que vem na ISO

| Área | Itens |
|---|---|
| Desktop | KDE Plasma (Wayland), SDDM, NetworkManager, Bluetooth, PipeWire |
| Drivers de vídeo | Mesa/Vulkan (AMD e Intel), NVIDIA open (`nvidia-open`, placas GTX 16xx/RTX 20xx ou mais novas) |
| Jogos | Steam, Lutris + Wine-staging (Battle.net), GameMode, MangoHud, Gamescope |
| Pós-instalação | Heroic (Epic/GOG) e ProtonUp-Qt (Proton-GE) via Flatpak no primeiro boot |
| Apps | Discord, Firefox |

## Otimizações

- `sysctl`: `vm.max_map_count` alto, swappiness para zram, cache de disco, BBR, `fq_codel`
- zram com zstd no lugar de swap em disco
- Escalonador de I/O por tipo de disco (NVMe, SSD, HDD) via udev
- Limites de arquivos abertos e prioridade de áudio
- NVIDIA com `modeset=1` (Wayland) e watchdogs de hardware desativados
- `power-profiles-daemon` e `fstrim.timer` ativos

Os arquivos ficam em `airootfs/etc/` e podem ser editados livremente.

## Como gerar a ISO

### Opção A: GitHub Actions (não precisa de Linux)

1. Crie um repositório no GitHub e envie o conteúdo desta pasta (a pasta `.github` precisa ficar na raiz).
2. Vá em **Actions → Build GameOS ISO → Run workflow**.
3. Ao terminar (cerca de 20 a 40 minutos), baixe a ISO em **Artifacts**.

### Opção B: num Arch Linux (ou VM Arch)

```bash
sudo pacman -S archiso
sudo ./build.sh        # a ISO sai em ./out
```

## Testar

Use uma VM antes de gravar em pendrive (QEMU, VirtualBox ou VMware, com 4 GB de RAM ou mais e EFI ativado). Em VM sem aceleração 3D, o Plasma em Wayland pode falhar; nesse caso, escolha a sessão X11 ou teste direto em hardware.

Para instalar no disco, abra um terminal na sessão live e rode:

```bash
sudo gameos-install
```

Ele abre o `archinstall` e, ao final, instala os pacotes e os ajustes do GameOS no sistema novo. As instruções aparecem na tela.

## Battle.net

Abra o Lutris, procure por **Battle.net** e instale pelo script oficial. Funciona na maioria dos casos via Wine, mas alguns jogos da Blizzard podem pedir ajustes.

## Limitações conhecidas

- **Anti-cheat de kernel** (Valorant, Vanguard, alguns títulos com Easy Anti-Cheat/BattlEye sem suporte a Linux) não roda no Linux. Consulte [areweanticheatyet.com](https://areweanticheatyet.com) antes de apostar num jogo.
- Placas NVIDIA antigas (anteriores à GTX 16xx) precisam de driver legado (AUR), que não vem nesta ISO.
- O instalador é o `archinstall` em modo texto, não um instalador gráfico.
- Kernel padrão do Arch (`linux`). Kernels como `linux-zen` ou CachyOS exigem DKMS para o driver NVIDIA.

## Próximos passos sugeridos

1. Kernel otimizado (zen ou CachyOS) com repositório próprio.
2. Instalador gráfico (Calamares).
3. Nome, logo, tema e papel de parede próprios.
4. Repositório de pacotes próprio para o `gameos-settings`.
