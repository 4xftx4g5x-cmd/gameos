#!/usr/bin/env bash
# HKOS - monta o perfil archiso (baseado no releng) e gera a ISO.
# Precisa rodar como root dentro de um Arch Linux (ou de um container archlinux).
# Quase tudo é escrito aqui mesmo (função put): atualizar = trocar build.sh,
# packages.extra e wallpaper.png.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-/tmp/gameos-work}"
OUT="${OUT:-$HERE/out}"
RELENG="${RELENG:-/usr/share/archiso/configs/releng}"
PROFILE="$WORK/profile"
AIROOT="$PROFILE/airootfs"
SK=usr/share/hkos/skel            # arquivos de usuário (home) do HKOS
WALL=usr/share/wallpapers/HKOS/hkos.png

[[ $EUID -eq 0 ]] || { echo "Rode como root." >&2; exit 1; }
[[ "${DRYRUN:-0}" == 1 ]] || command -v mkarchiso >/dev/null || pacman -Sy --noconfirm archiso

# put <modo> <caminho-no-airootfs>  (conteúdo vem do stdin)
put() { mkdir -p "$(dirname "$AIROOT/$2")"; rm -f "$AIROOT/$2"; cat > "$AIROOT/$2"; chmod "$1" "$AIROOT/$2"; }

rm -rf "$WORK"
mkdir -p "$PROFILE" "$OUT"
cp -r "$RELENG"/. "$PROFILE/"
[[ -d "$HERE/airootfs" ]] && cp -rT "$HERE/airootfs" "$AIROOT"

###############################################################################
# 1) PACOTES: tira tudo que não é essencial e põe os do HKOS
###############################################################################
PKGLIST="$PROFILE/packages.x86_64"
REMOVE=(
  linux broadcom-wl b43-fwcutter                       # kernel padrão (trocado pelo zen)
  brltty espeakup livecd-sounds                        # acessibilidade/voz
  clonezilla partclone partimage fsarchiver testdisk ddrescue gpart fatresize
  darkhttpd irssi lftp nmap tcpdump gpm mc screen tmux openssh
  openvpn openconnect vpnc ppp pptpclient rp-pppoe wvdial xl2tpd
  modemmanager usb_modeswitch nfs-utils nbd open-iscsi udftools usbmuxd
  hyperv qemu-guest-agent virtualbox-guest-utils-nox open-vm-tools
  reiserfsprogs jfsutils nilfs-utils cloud-init ndisc6 dmraid
  sg3_utils sdparm lsscsi bind dnsmasq iwd reflector
  man-db man-pages vim
  archinstall refind grub                               # o HKOS tem instalador próprio (systemd-boot)
  bcachefs-tools btrfs-progs mdadm lvm2 mmc-utils bolt
  tpm2-tools tpm2-tss sequoia-sq openpgp-card-tools pcsclite libfido2
  lynx wireless_tools dhcpcd                           # (zsh fica: o root do releng usa zsh)
  foot-terminfo ghostty-terminfo kitty-terminfo kmscon-terminfo rxvt-unicode-terminfo
)
for p in "${REMOVE[@]}"; do sed -i "/^${p}\$/d" "$PKGLIST"; done
grep -vE '^\s*(#|$)' "$HERE/packages.extra" >> "$PKGLIST"

cat >> "$PROFILE/pacman.conf" <<'EOF'

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF
sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 10/' "$PROFILE/pacman.conf"
grep -q '^ParallelDownloads' "$PROFILE/pacman.conf" || sed -i '/^\[options\]/a ParallelDownloads = 10' "$PROFILE/pacman.conf"

###############################################################################
# 1b) KERNEL PRÓPRIO linux-hkos (opcional; se falhar, cai no linux-zen)
#     HKOS_KERNEL=0 desliga | KCACHE=<pasta> reaproveita o kernel já compilado
#     HKOS_KFLAGS="-march=x86-64-v3" liga o ajuste p/ CPUs com AVX2 (opcional)
###############################################################################
KERNEL=linux-zen
KREPO="$WORK/hkosrepo"
if [[ "${HKOS_KERNEL:-1}" == 1 ]]; then
  if [[ "${DRYRUN:-0}" == 1 ]]; then
    KERNEL=linux-hkos                       # simulação: só testa a troca de nomes
  else
    mkdir -p "$KREPO"
    cat > "$WORK/kbuild.sh" <<'KBUILD_EOF'
#!/usr/bin/env bash
# Compila o linux-hkos a partir do PKGBUILD oficial do linux-zen (Arch).
set -euo pipefail
REPO="$1"; KCACHE="${KCACHE:-}"
if [[ -n "$KCACHE" ]] && compgen -G "$KCACHE/linux-hkos-headers-*.pkg.tar.zst" >/dev/null; then
  echo "==> kernel linux-hkos já compilado (cache), reaproveitando"
  cp "$KCACHE"/linux-hkos-*.pkg.tar.zst "$REPO/"
  exit 0
fi
pacman -S --needed --noconfirm base-devel git bc cpio gettext libelf pahole perl python tar xz zstd lz4
id builder >/dev/null 2>&1 || useradd -m builder
B=/home/builder/k
rm -rf "$B"; mkdir -p "$B/out"
git clone --depth 1 https://gitlab.archlinux.org/archlinux/packaging/packages/linux-zen.git "$B/src"
cd "$B/src"
python - <<'PY'
import re
s = open('PKGBUILD').read()
def sub(pat, new, flags=re.M):
    global s
    s, n = re.subn(pat, new, s, count=1, flags=flags)
    assert n == 1, pat
sub(r'^pkgbase=linux-zen\s*$', 'pkgbase=linux-hkos')
sub(r'^pkgname=\(.*\)\s*$', 'pkgname=("$pkgbase" "$pkgbase-headers")')
sub(r'^makedepends=\([^)]*\)', 'makedepends=(bc cpio gettext libelf pahole perl python tar xz zstd)')
s = re.sub(r'^.*make .*htmldocs.*\n', '', s, flags=re.M)      # sem documentação
open('PKGBUILD', 'w').write(s)
PY
[[ -f config.x86_64 ]] || { echo "config.x86_64 não encontrado"; exit 1; }
cat >> config.x86_64 <<'CFG'

# --- ajustes HKOS (jogos / baixa latência) ---
# agendador/tempo
CONFIG_HZ_1000=y
CONFIG_HZ=1000
CONFIG_PREEMPT=y
CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y
CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE_O3=y
# boot mais rápido: kernel comprimido em LZ4 (descompacta bem mais rápido que zstd)
CONFIG_KERNEL_LZ4=y
# CONFIG_KERNEL_ZSTD is not set
# Wine/Proton e rede
CONFIG_NTSYNC=y
CONFIG_TCP_CONG_BBR=y
CONFIG_DEFAULT_BBR=y
CONFIG_DEFAULT_TCP_CONG="bbr"
# menos trabalho no caminho de cada chamada do sistema (já rodamos com mitigations=off)
# CONFIG_AUDIT is not set
# CONFIG_SCHEDSTATS is not set
# CONFIG_SLUB_DEBUG is not set
# CONFIG_DEBUG_PREEMPT is not set
# CONFIG_PROFILING is not set
# CONFIG_PAGE_OWNER is not set
# CONFIG_PAGE_POISONING is not set
# endurecimento que custa desempenho (troca consciente: segurança por FPS)
# CONFIG_INIT_ON_ALLOC_DEFAULT_ON is not set
# CONFIG_INIT_ON_FREE_DEFAULT_ON is not set
# CONFIG_FORTIFY_SOURCE is not set
# CONFIG_HARDENED_USERCOPY is not set
# CONFIG_RANDOMIZE_KSTACK_OFFSET_DEFAULT is not set
# CONFIG_SLAB_FREELIST_HARDENED is not set
# CONFIG_SLAB_FREELIST_RANDOM is not set
# CONFIG_SHUFFLE_PAGE_ALLOCATOR is not set
# CONFIG_RANDOM_KMALLOC_CACHES is not set
# CONFIG_ZERO_CALL_USED_REGS is not set
# mitigações de CPU compiladas FORA (código de entrada/saída do kernel mais curto)
# CONFIG_MITIGATION_PAGE_TABLE_ISOLATION is not set
# CONFIG_MITIGATION_RETPOLINE is not set
# CONFIG_MITIGATION_RETHUNK is not set
# CONFIG_MITIGATION_UNRET_ENTRY is not set
# CONFIG_MITIGATION_CALL_DEPTH_TRACKING is not set
# CONFIG_MITIGATION_IBPB_ENTRY is not set
# CONFIG_MITIGATION_IBRS_ENTRY is not set
# CONFIG_MITIGATION_SRSO is not set
# CONFIG_MITIGATION_SLS is not set
CFG
chown -R builder "$B"
NP="$(nproc)"
su builder -c "cd '$B/src' && MAKEFLAGS='-j$NP' KCFLAGS='${HKOS_KFLAGS:--pipe}' PKGDEST='$B/out' timeout 170m makepkg --nodeps --skipinteg --noconfirm --nocheck"
ls "$B"/out/linux-hkos-headers-*.pkg.tar.zst >/dev/null
for f in "$B"/out/linux-hkos-*.pkg.tar.zst; do
  case "$f" in *-docs-*|*-debug-*) continue;; esac
  cp "$f" "$REPO/"
  [[ -n "$KCACHE" ]] && { mkdir -p "$KCACHE"; cp "$f" "$KCACHE/"; }
done
echo "==> kernel linux-hkos pronto"
KBUILD_EOF
    # roda em processo separado: se qualquer coisa falhar, o HKOS segue com o linux-zen
    if bash "$WORK/kbuild.sh" "$KREPO" && ls "$KREPO"/linux-hkos-headers-*.pkg.tar.zst >/dev/null 2>&1; then
      repo-add "$KREPO/hkos.db.tar.zst" "$KREPO"/linux-hkos-*.pkg.tar.zst
      printf '\n[hkos]\nSigLevel = Optional TrustAll\nServer = file://%s\n' "$KREPO" >> "$PROFILE/pacman.conf"
      KERNEL=linux-hkos
    else
      echo "!!! Falha ao compilar o linux-hkos: usando o linux-zen." >&2
    fi
  fi
fi
echo "==> Kernel desta ISO: $KERNEL"
if [[ "$KERNEL" != linux-zen ]]; then
  sed -i -e "s/^linux-zen\$/$KERNEL/" -e "s/^linux-zen-headers\$/$KERNEL-headers/" "$PKGLIST"
fi

###############################################################################
# 2) KERNEL: preset do initramfs, entradas de boot, nome e parâmetros
###############################################################################
rm -f "$AIROOT/etc/mkinitcpio.d/linux.preset"
put 644 "etc/mkinitcpio.d/${KERNEL}.preset" <<EOF
# mkinitcpio preset do HKOS (kernel ${KERNEL})
PRESETS=('archiso')

ALL_kver='/boot/vmlinuz-${KERNEL}'
archiso_config='/etc/mkinitcpio.conf.d/archiso.conf'

archiso_image="/boot/initramfs-${KERNEL}.img"
EOF

LIVE_CMD='mitigations=off nowatchdog split_lock_detect=off audit=0 nvme_core.default_ps_max_latency_us=0 usbcore.autosuspend=-1 amdgpu.ppfeaturemask=0xffffffff pcie_aspm=off processor.max_cstate=1 intel_idle.max_cstate=1 threadirqs skew_tick=1 iommu=pt workqueue.power_efficient=0 cpufreq.default_governor=performance amd_pstate=active usbhid.mousepoll=1 i915.enable_psr=0'
for d in grub syslinux efiboot; do
  [[ -d "$PROFILE/$d" ]] || continue
  find "$PROFILE/$d" -type f -exec sed -i \
    -e "s|vmlinuz-linux|vmlinuz-${KERNEL}|g" \
    -e "s|initramfs-linux\.img|initramfs-${KERNEL}.img|g" \
    -e "s|archisosearchuuid=%ARCHISO_UUID%|& ${LIVE_CMD}|g" \
    -e 's|Arch Linux|HKOS|g' {} +
done

###############################################################################
# 2b) Logo HK no menu de boot (BIOS/syslinux; o menu UEFI é só texto)
if [[ -f "$HERE/boot-splash.png" && -d "$PROFILE/syslinux" ]]; then
  cp "$HERE/boot-splash.png" "$PROFILE/syslinux/splash.png"
fi

###############################################################################
# 3) IDENTIDADE, PERMISSÕES E USUÁRIO LIVE
###############################################################################
sed -i \
  -e 's|^iso_name=.*|iso_name="hkos"|' \
  -e 's|^iso_label=.*|iso_label="HKOS_$(date +%Y%m)"|' \
  -e 's|^iso_application=.*|iso_application="HKOS Live/Install ISO"|' \
  -e "s|^airootfs_image_tool_options=.*|airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '15' '-b' '1M')|" \
  -e '/^file_permissions=(/a\  ["/usr/local/bin/hkos-install"]="0:0:755"' \
  -e '/^file_permissions=(/a\  ["/etc/sudoers.d/10-gameos"]="0:0:440"' \
  -e '/^file_permissions=(/a\  ["/etc/sudoers.d/20-hkos-gpu"]="0:0:440"' \
  -e "/^file_permissions=(/a\\  [\"/$SK/.xinitrc\"]=\"0:0:755\"" \
  "$PROFILE/profiledef.sh"

for s in hkos-mode hkos-info hkos-tweaks hkos-proton-ge hkos-heroic hkos-explorer hkos-run hkos-battlenet hkos-gpu hkos-gpu-root hkos-game hkos-game-root hkos-bench hkos-fan hkos-ajuda hkos-loja; do
  sed -i "/^file_permissions=(/a\\  [\"/usr/local/bin/$s\"]=\"0:0:755\"" "$PROFILE/profiledef.sh"
done

# Restos de versões anteriores (Plasma/SDDM/Flatpak) que não existem mais
rm -rf "$AIROOT/etc/sddm.conf.d" "$AIROOT/usr/local/bin/gameos-install" \
       "$AIROOT/usr/local/bin/gameos-firstboot" \
       "$AIROOT/usr/lib/systemd/system/gameos-firstboot.service"

put 644 etc/hostname <<'EOF'
hkos
EOF
put 644 etc/os-release <<'EOF'
NAME="HKOS"
PRETTY_NAME="HKOS (HK Tech, base Arch Linux)"
ID=arch
ID_LIKE=arch
BUILD_ID=rolling
ANSI_COLOR="38;2;230;230;230"
HOME_URL="https://archlinux.org/"
LOGO=archlinux-logo
EOF
put 644 etc/motd <<'EOF'

  HKOS - HK Tech | sistema Linux ultraleve para jogos (base Arch Linux)

  Instalar no disco:   sudo hkos-install   (ou botão direito na área de trabalho)
  Steam, Discord e Firefox estão na barra de baixo.
  Comandos e ajuda:   hkos-ajuda      Instalar programas/drivers:   hkos-loja

EOF
ln -sf /usr/share/zoneinfo/America/Sao_Paulo "$AIROOT/etc/localtime"
put 644 etc/pacman.d/mirrorlist <<'EOF'
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
Server = https://mirrors.kernel.org/archlinux/$repo/os/$arch
Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch
EOF
put 644 etc/vconsole.conf <<'EOF'
KEYMAP=br-abnt2
FONT=ter-v16n
EOF
put 644 etc/X11/xorg.conf.d/00-keyboard.conf <<'EOF'
Section "InputClass"
    Identifier "hkos-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "br"
    Option "XkbModel" "abnt2"
EndSection
EOF

# Usuário da sessão live (sem senha). Entra direto no desktop, sem gerenciador de login.
grep -q '^gamer:' "$AIROOT/etc/passwd"  || echo 'gamer:x:1000:1000:HKOS Live:/home/gamer:/bin/bash' >> "$AIROOT/etc/passwd"
grep -q '^gamer:' "$AIROOT/etc/shadow"  || echo 'gamer::14871::::::' >> "$AIROOT/etc/shadow"
grep -q '^gamer:' "$AIROOT/etc/group"   || echo 'gamer:x:1000:' >> "$AIROOT/etc/group"
grep -q '^gamer:' "$AIROOT/etc/gshadow" || echo 'gamer:!::' >> "$AIROOT/etc/gshadow"
put 644 etc/tmpfiles.d/gameos-live.conf <<'EOF'
C /home/gamer 0700 gamer gamer - /usr/share/hkos/skel
Z /home/gamer - gamer gamer -
EOF
put 644 etc/systemd/system/getty@tty1.service.d/autologin.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --autologin gamer %I $TERM
EOF

###############################################################################
# 4) SERVIÇOS: remove o que o live não precisa
###############################################################################
find "$AIROOT/etc/systemd/system" \( \
  -name 'livecd-*' -o -name 'espeakup*' -o -name 'brltty*' -o -name 'hv_*' \
  -o -name 'vboxservice*' -o -name 'vmtoolsd*' -o -name 'vmware-*' \
  -o -name 'qemu-guest-agent*' -o -name 'systemd-networkd*' -o -name 'iwd.service' \
  -o -name 'ModemManager*' -o -name 'sshd*' -o -name 'reflector*' \) \
  -exec rm -rf {} + 2>/dev/null || true

enable() { mkdir -p "$AIROOT/etc/systemd/system/$2.wants"; ln -sf "/usr/lib/systemd/system/$1" "$AIROOT/etc/systemd/system/$2.wants/$1"; }
enable NetworkManager.service multi-user.target
enable scx.service multi-user.target
enable earlyoom.service multi-user.target
enable nvidia-persistenced.service multi-user.target

###############################################################################
# 5) DESKTOP ULTRALEVE: Openbox + tint2, escuro, sem compositor e sem animações
###############################################################################
if [[ -f "$HERE/wallpaper.png" ]]; then
  mkdir -p "$(dirname "$AIROOT/$WALL")"; cp "$HERE/wallpaper.png" "$AIROOT/$WALL"; HAS_WALL=1
else
  echo "AVISO: wallpaper.png não encontrado; fundo ficará preto." >&2; HAS_WALL=0
fi

put 644 $SK/.bash_profile <<'EOF'
[[ -f ~/.bashrc ]] && . ~/.bashrc
# Sem gerenciador de login: no primeiro terminal sobe o modo console (se pedido) ou o desktop
if [[ -z "${DISPLAY:-}" && "${XDG_VTNR:-0}" == 1 ]]; then
  FLAG="$HOME/.config/hkos-console"
  if [[ -f "$FLAG" ]]; then
    [[ "$(cat "$FLAG")" == once ]] && rm -f "$FLAG"
    gamescope -e -f -- steam -gamepadui > "$HOME/.gamescope.log" 2>&1 || true
  fi
  exec startx -- -nolisten tcp vt1 > "$HOME/.startx.log" 2>&1
fi
EOF
put 755 $SK/.xinitrc <<'EOF'
#!/bin/sh
xrdb -merge "$HOME/.Xresources"
xset s off s noblank -dpms b off
xset r rate 250 40
OB="$HOME/.config/openbox"
if [ ! -f "$OB/rc.xml" ]; then
  mkdir -p "$OB"
  cp /etc/xdg/openbox/rc.xml "$OB/rc.xml"
  sed -i -e 's|<name>Clearlooks</name>|<name>HKOS</name>|' \
         -e 's|<animateIconify>yes|<animateIconify>no|' \
         -e 's|<drawContents>yes|<drawContents>no|' \
         -e 's|<number>4</number>|<number>1</number>|' \
         -e '/<keyboard>/r /usr/share/hkos/keybinds.xml' "$OB/rc.xml"
fi
exec openbox-session
EOF
put 644 usr/share/themes/HKOS/openbox-3/themerc <<'EOF'
# HKOS - tema Openbox: preto total, texto branco
border.width: 1
padding.width: 8
padding.height: 4
window.handle.width: 0
window.client.padding.width: 0
window.label.text.justify: left

window.*.border.color: #3a3a3a
window.active.border.color: #e6e6e6
window.*.title.bg: flat solid
window.*.title.bg.color: #000000
window.*.title.separator.color: #000000
window.*.label.bg: parentrelative
window.active.label.text.color: #ffffff
window.inactive.label.text.color: #8a8a8a
window.*.label.text.font: shadow=n
window.*.handle.bg: flat solid
window.*.handle.bg.color: #000000
window.*.grip.bg: flat solid
window.*.grip.bg.color: #000000

window.*.button.*.bg: flat solid
window.*.button.*.bg.color: #000000
window.active.button.*.image.color: #ffffff
window.inactive.button.*.image.color: #8a8a8a
window.*.button.hover.bg.color: #1c1c1c
window.*.button.pressed.bg.color: #2a2a2a
window.*.button.disabled.image.color: #444444

menu.border.color: #3a3a3a
menu.title.bg: flat solid
menu.title.bg.color: #000000
menu.title.text.color: #ffffff
menu.title.text.justify: left
menu.items.bg: flat solid
menu.items.bg.color: #000000
menu.items.text.color: #cccccc
menu.items.disabled.text.color: #555555
menu.items.active.bg: flat solid
menu.items.active.bg.color: #e6e6e6
menu.items.active.text.color: #000000
menu.separator.color: #3a3a3a
menu.separator.width: 1
menu.separator.padding.width: 6
menu.separator.padding.height: 3
menu.*.text.font: shadow=n

osd.border.color: #e6e6e6
osd.border.width: 1
osd.bg: flat solid
osd.bg.color: #000000
osd.label.bg: flat solid
osd.label.bg.color: #000000
osd.label.text.color: #ffffff
osd.hilight.bg: flat solid
osd.hilight.bg.color: #e6e6e6
osd.unhilight.bg: flat solid
osd.unhilight.bg.color: #2a2a2a
EOF
put 644 $SK/.config/gtk-3.0/gtk.css <<'EOF'
/* HKOS - preto total */
window, .background, headerbar, .titlebar, dialog, popover, menu, .view, treeview, entry, textview text {
  background-color: #000000; color: #e6e6e6;
}
button { background-image: none; background-color: #0a0a0a; border-color: #333333; color: #e6e6e6; }
button:hover { background-color: #1a1a1a; }
selection, *:selected { background-color: #e6e6e6; color: #000000; }
EOF
put 644 $SK/.config/mimeapps.list <<'EOF'
[Default Applications]
inode/directory=pcmanfm.desktop
EOF
put 644 usr/share/hkos/keybinds.xml <<'EOF'
<!-- HKOS: atalhos parecidos com o Windows -->
<keybind key="W-e"><action name="Execute"><command>hkos-explorer</command></action></keybind>
<keybind key="W-r"><action name="Execute"><command>hkos-run</command></action></keybind>
<keybind key="C-Escape"><action name="ShowMenu"><menu>root-menu</menu></action></keybind>
<keybind key="W-Up"><action name="ToggleMaximize"/></keybind>
<keybind key="W-Down"><action name="Iconify"/></keybind>
<keybind key="W-Left"><action name="UnmaximizeFull"/><action name="MoveResizeTo"><x>0</x><y>0</y><width>50%</width><height>100%</height></action></keybind>
<keybind key="W-Right"><action name="UnmaximizeFull"/><action name="MoveResizeTo"><x>50%</x><y>0</y><width>50%</width><height>100%</height></action></keybind>
EOF
put 755 usr/local/bin/hkos-battlenet <<'TOOL_EOF'
#!/usr/bin/env bash
# hkos-battlenet - instala (na 1ª vez) o Lutris + Wine e abre o Lutris para o Battle.net.
# Fica fora do ISO para o sistema ser bem mais leve.
SUDO=(); [[ $EUID -eq 0 ]] || SUDO=(sudo)
install_bnet() {
  echo "O Battle.net usa Lutris + Wine (cerca de 1,5 GB, precisa de internet)."
  if [[ -d /run/archiso ]]; then
    echo "Modo live (pendrive): usa muita memória e some ao reiniciar."
    echo "Prefira instalar o HKOS no disco antes (sudo hkos-install)."
  fi
  read -rp "Instalar agora? [s/N] " r; [[ "$r" =~ ^[sS]$ ]] || return 1
  local U=-Syu; [[ -d /run/archiso ]] && U=-Sy
  "${SUDO[@]}" pacman "$U" --needed --noconfirm lutris wine-staging winetricks wine-mono wine-gecko \
    || { echo "Falhou (sem internet ou pouco espaço)."; return 1; }
  echo "Pronto."
}
case "${1:-}" in
  install) install_bnet; read -rp "Enter para fechar..." _ ;;
  *)
    if ! command -v lutris >/dev/null 2>&1; then
      if [[ -t 0 ]]; then install_bnet || { read -rp "Enter para fechar..." _; exit 1; }
      else xterm -e "$0" install; fi
    fi
    command -v lutris >/dev/null 2>&1 && exec lutris ;;
esac
TOOL_EOF

put 755 usr/local/bin/hkos-game-root <<'TOOL_EOF'
#!/usr/bin/env bash
# hkos-game-root - parte root do hkos-game (agendador e modo do V-Cache). Só comandos fixos.
SCXF="${HKOS_SCX_FILE:-/etc/default/scx}"
case "${1:-}" in
  sched)
    case "${2:-}" in
      lavd)    S=scx_lavd;    F='--performance' ;;
      bpfland) S=scx_bpfland; F='-m performance' ;;
      off)     systemctl stop scx.service; exit $? ;;
      *) exit 2 ;;
    esac
    printf "SCX_SCHEDULER=%s\nSCX_FLAGS='%s'\n" "$S" "$F" > "$SCXF" && systemctl restart scx.service ;;
  x3d)
    case "${2:-}" in cache|frequency) ;; *) exit 2 ;; esac
    f="$(ls ${HKOS_X3D_GLOB:-/sys/bus/platform/drivers/amd_x3d_vcache/*/amd_x3d_mode} 2>/dev/null | head -1)"
    [[ -n "$f" ]] || exit 3
    echo "$2" > "$f" ;;
  *) echo "uso: hkos-game-root sched lavd|bpfland|off | x3d cache|frequency" >&2; exit 1 ;;
esac
TOOL_EOF

put 755 usr/local/bin/hkos-game <<'TOOL_EOF'
#!/usr/bin/env bash
# hkos-game - roda um jogo com ajustes de FPS e latência.
# Steam > Propriedades > Opções de inicialização:   hkos-game %command%
CFGDIR="${HKOS_GAME_DIR:-$HOME/.config/hkos-game}"
if [[ -n "${HKOS_GAME_ROOT:-}" ]]; then ROOT=("$HKOS_GAME_ROOT")
elif [[ $EUID -eq 0 ]]; then ROOT=(/usr/local/bin/hkos-game-root)
else ROOT=(sudo -n /usr/local/bin/hkos-game-root); fi
SCXF="${HKOS_SCX_FILE:-/etc/default/scx}"
X3DGLOB="${HKOS_X3D_GLOB:-/sys/bus/platform/drivers/amd_x3d_vcache/*/amd_x3d_mode}"

NOVSYNC=0 LOWLAT=0 GLTHREADS=0 NOOVERLAY=0 GAMEMODE=1 MANGO=0 X3D=0
FPS="" SCHED="" PIN="" RESERVE=""
REST=()

usage() { cat <<'EOF'
hkos-game [opções] %command%        (no Steam: Opções de inicialização)
  --novsync      sem V-Sync/VRR (mais FPS, a imagem pode rasgar)
  --fps N        limita o FPS (frame pacing mais estável)
  --lowlat       menos fila de quadros e CPU sem dormir (menos latência)
  --glthreads    OpenGL em várias threads (teste jogo a jogo)
  --nooverlay    tira o overlay do Steam (acaba travadas em alguns jogos)
  --mangohud     mostra FPS e temperaturas
  --nogamemode   não usa o GameMode (padrão: usa)
  --sched lavd|bpfland|off   troca o agendador só durante o jogo
  --pin 0-5      roda o jogo só nesses núcleos
  --reserve N    deixa N núcleos livres para o sistema (Discord, navegador)
  --x3d          CPU AMD X3D: prioriza o V-Cache durante o jogo
  --noprofile    ignora o perfil salvo do jogo
Perfis por jogo (usam o AppID do Steam):
  hkos-game save APPID [opções]      salva as opções para aquele jogo
  hkos-game list                     lista os perfis
  hkos-game remove APPID             apaga um perfil
  Depois basta usar:  hkos-game %command%
EOF
}
die() { echo "hkos-game: opção inválida. Veja: hkos-game help" >&2; exit 2; }

parse() {
  REST=()
  while (( $# )); do
    case "$1" in
      --novsync) NOVSYNC=1 ;;   --lowlat) LOWLAT=1 ;;     --glthreads) GLTHREADS=1 ;;
      --nooverlay) NOOVERLAY=1 ;; --nogamemode) GAMEMODE=0 ;; --mangohud) MANGO=1 ;;
      --x3d) X3D=1 ;;            --noprofile) ;;
      --fps)     shift; [[ "${1:-}" =~ ^[0-9]{1,4}$ ]] || die; FPS="$1" ;;
      --sched)   shift; case "${1:-}" in lavd|bpfland|off) SCHED="$1" ;; *) die ;; esac ;;
      --pin)     shift; [[ "${1:-}" =~ ^[0-9,-]+$ ]] || die; PIN="$1" ;;
      --reserve) shift; [[ "${1:-}" =~ ^[0-9]{1,2}$ ]] || die; RESERVE="$1" ;;
      --) shift; REST=("$@"); return 0 ;;
      *)  REST=("$@"); return 0 ;;
    esac
    shift
  done
}

case "${1:-}" in
  help|-h|--help|"") usage; exit 0 ;;
  list)   mkdir -p "$CFGDIR"; for f in "$CFGDIR"/*.conf; do [[ -e "$f" ]] && echo "$(basename "$f" .conf): $(cat "$f")"; done; exit 0 ;;
  remove) [[ "${2:-}" =~ ^[0-9]+$ ]] || die; rm -f "$CFGDIR/$2.conf"; echo "Perfil $2 removido."; exit 0 ;;
  save)
    [[ "${2:-}" =~ ^[0-9]+$ ]] || die
    id="$2"; shift 2; parse "$@"; (( ${#REST[@]} == 0 )) || die
    mkdir -p "$CFGDIR"; echo "$*" > "$CFGDIR/$id.conf"; echo "Perfil do jogo $id salvo: $*"; exit 0 ;;
esac

# perfil do jogo (AppID vem do Steam), depois as opções da linha de comando
noprof=0; for a in "$@"; do [[ "$a" == --noprofile ]] && noprof=1; done
if (( ! noprof )) && [[ "${SteamAppId:-}" =~ ^[0-9]+$ && -f "$CFGDIR/$SteamAppId.conf" ]]; then
  read -ra P < "$CFGDIR/$SteamAppId.conf"; parse "${P[@]}"
fi
parse "$@"
(( ${#REST[@]} > 0 )) || { usage; exit 1; }

# ---- ambiente ----
(( NOVSYNC ))   && export __GL_SYNC_TO_VBLANK=0 __GL_VRR_ALLOWED=0 vblank_mode=0
(( GLTHREADS )) && export __GL_THREADED_OPTIMIZATIONS=1 mesa_glthread=true
(( LOWLAT ))    && export __GL_MaxFramesAllowed=1
(( NOOVERLAY )) && export LD_PRELOAD=""
USE_MANGO=$MANGO
if [[ -n "$FPS" ]]; then
  export DXVK_FRAME_RATE="$FPS"
  export MANGOHUD_CONFIG="fps_limit=$FPS$( (( MANGO )) || echo ',no_display' )"
  USE_MANGO=1
fi

# núcleos livres para o sistema
if [[ -z "$PIN" && -n "$RESERVE" ]]; then
  n="$(nproc --all 2>/dev/null || echo 1)"
  (( n > RESERVE )) && PIN="0-$(( n - RESERVE - 1 ))"
fi

# CPU sem dormir (cpu_dma_latency), só enquanto o jogo roda
LATFD=""
if (( LOWLAT )) && exec {LATFD}<>/dev/cpu_dma_latency 2>/dev/null; then printf '\0\0\0\0' >&"$LATFD"; else LATFD=""; fi

# agendador e V-Cache (guardam o estado anterior para restaurar)
prev_sched="$(grep -m1 '^SCX_SCHEDULER=' "$SCXF" 2>/dev/null | cut -d= -f2 | tr -d "'\"")"
prev_active="$(systemctl is-active scx.service 2>/dev/null)"
x3dfile="$(ls $X3DGLOB 2>/dev/null | head -1)"; prev_x3d=""
[[ -n "$x3dfile" ]] && prev_x3d="$(tr -d '[:space:]' < "$x3dfile" 2>/dev/null)"
changed_sched=0; changed_x3d=0
[[ -n "$SCHED" ]] && "${ROOT[@]}" sched "$SCHED" 2>/dev/null && changed_sched=1
if (( X3D )) && [[ -n "$x3dfile" ]]; then "${ROOT[@]}" x3d cache 2>/dev/null && changed_x3d=1; fi

restore() {
  if (( changed_sched )); then
    case "$prev_sched" in
      scx_lavd)    "${ROOT[@]}" sched lavd 2>/dev/null ;;
      scx_bpfland) "${ROOT[@]}" sched bpfland 2>/dev/null ;;
    esac
    [[ "$prev_active" == active ]] || "${ROOT[@]}" sched off 2>/dev/null
  fi
  if (( changed_x3d )) && [[ "$prev_x3d" =~ ^(cache|frequency)$ ]]; then "${ROOT[@]}" x3d "$prev_x3d" 2>/dev/null; fi
  [[ -n "$LATFD" ]] && exec {LATFD}>&-
  return 0
}

CMD=()
[[ -n "$PIN" ]] && command -v taskset >/dev/null && CMD+=(taskset -c "$PIN")
(( GAMEMODE )) && command -v gamemoderun >/dev/null && CMD+=(gamemoderun)
(( USE_MANGO )) && command -v mangohud >/dev/null && CMD+=(mangohud)
CMD+=("${REST[@]}")

"${CMD[@]}" & pid=$!
trap 'kill -TERM "$pid" 2>/dev/null' TERM INT
wait "$pid"; rc=$?
restore
exit "$rc"
TOOL_EOF

put 755 usr/local/bin/hkos-bench <<'TOOL_EOF'
#!/usr/bin/env bash
# hkos-bench - mede FPS médio, 1% low e 0,1% low com o MangoHud.
# Steam > Opções de inicialização:   hkos-bench -t 120 %command%     (ou:  hkos-bench -n "antes" -t 120 %command%)
# Depois:  hkos-bench show   |   hkos-bench compare   (compara as duas últimas medições)
BASE="${HKOS_BENCH_DIR:-$HOME/.local/share/hkos-bench}"
RES="$BASE/resultados.txt"

calc() { # calc arquivo.csv  ->  "media 1low 01low amostras"
  local f="$1" tmp; tmp="$(mktemp)"
  awk -F, 'hdr==0 && $1=="fps" { for(i=1;i<=NF;i++) if($i=="frametime") c=i; hdr=1; next }
           hdr && c && ($c+0)>0 { print $c+0 }' "$f" | sort -rn > "$tmp"
  awk '{a[NR]=$1; s+=$1}
       END{ if(NR==0){print "0 0 0 0"; exit}
            n1=int(NR*0.01); if(n1<1)n1=1; n2=int(NR*0.001); if(n2<1)n2=1
            for(i=1;i<=n1;i++) t1+=a[i]; for(i=1;i<=n2;i++) t2+=a[i]
            printf "%.1f %.1f %.1f %d\n", 1000/(s/NR), 1000/(t1/n1), 1000/(t2/n2), NR }' "$tmp"
  rm -f "$tmp"
}
fmt() { awk -v n="$1" '{printf "%s: média %s FPS | 1%% low %s | 0,1%% low %s (%s quadros)\n", n, $1,$2,$3,$4}'; }

case "${1:-}" in
  show)    if [[ -f "$RES" ]]; then awk -F'|' '{printf "%-16s média %7.1f | 1%% low %7.1f | 0,1%% low %7.1f\n", $1,$2,$3,$4}' "$RES"; else echo "Nenhuma medição ainda."; fi; exit 0 ;;
  compare)
    [[ -f "$RES" ]] && (( $(wc -l < "$RES") >= 2 )) || { echo "Faça duas medições primeiro."; exit 1; }
    a="$(tail -2 "$RES" | head -1)"; b="$(tail -1 "$RES")"
    IFS='|' read -r na ma la1 la2 _ <<<"$a"; IFS='|' read -r nb mb lb1 lb2 _ <<<"$b"
    awk -v na="$na" -v nb="$nb" -v ma="$ma" -v mb="$mb" -v la="$la1" -v lb="$lb1" -v xa="$la2" -v xb="$lb2" 'BEGIN{
      printf "%-14s média %6.1f | 1%% low %6.1f | 0,1%% low %6.1f\n", na, ma, la, xa
      printf "%-14s média %6.1f | 1%% low %6.1f | 0,1%% low %6.1f\n", nb, mb, lb, xb
      printf "Diferença: média %+.1f%% | 1%% low %+.1f%% | 0,1%% low %+.1f%%\n", (mb-ma)*100/ma, (lb-la)*100/la, (xb-xa)*100/xa }'
    exit 0 ;;
  help|-h|--help|"") sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

T=120; NAME="medicao-$(date +%H%M)"
while [[ "${1:-}" == -* ]]; do
  case "$1" in
    -t) shift; [[ "${1:-}" =~ ^[0-9]{1,4}$ ]] || { echo "tempo inválido"; exit 2; }; T="$1" ;;
    -n) shift; NAME="$(printf '%s' "${1:-}" | tr -cd 'A-Za-z0-9 ._-')" ;;
    --) shift; break ;;
    *)  echo "opção inválida"; exit 2 ;;
  esac; shift
done
(( $# > 0 )) || { echo "uso: hkos-bench [-t segundos] [-n nome] -- comando"; exit 1; }
command -v mangohud >/dev/null || { echo "mangohud ausente."; exit 1; }

DIR="$BASE/logs/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$DIR"
export MANGOHUD=1 MANGOHUD_CONFIG="output_folder=$DIR,log_duration=$T,autostart_log=10,no_display"
mangohud "$@"; rc=$?
F="$(ls -t "$DIR"/*.csv 2>/dev/null | grep -v summary | head -1)"
if [[ -n "$F" ]]; then
  read -r m l1 l01 n < <(calc "$F")
  if (( n > 0 )); then
    mkdir -p "$BASE"; echo "$NAME|$m|$l1|$l01|$n" >> "$RES"
    out="$(echo "$m $l1 $l01 $n" | fmt "$NAME")"; echo "$out"; echo "$out" > "$HOME/hkos-bench-ultimo.txt"
    command -v notify-send >/dev/null && notify-send "HKOS Bench" "$out"
  fi
else
  echo "Sem log do MangoHud (o jogo fechou antes de 10 s?)."
fi
exit "$rc"
TOOL_EOF

put 755 usr/local/bin/hkos-gpu-root <<'TOOL_EOF'
#!/usr/bin/env bash
# hkos-gpu-root - parte root do hkos-gpu. Só aceita comandos fixos com números validados.
DRM="${HKOS_DRM:-/sys/class/drm}"
isint() { [[ "${1:-}" =~ ^[0-9]{1,5}$ ]]; }
amd_dev() { local c; for c in "$DRM"/card*/device; do grep -qs 0x1002 "$c/vendor" && { echo "$c"; return 0; }; done; return 1; }
amd_hw() { local h; h="$(ls -d "$1"/hwmon/hwmon* 2>/dev/null | head -1)"; [[ -n "$h" ]] && echo "$h"; }
cmd="${1:-}"; arg="${2:-}"
case "$cmd" in
  nv-power)  isint "$arg" && (( arg >= 20 && arg <= 600 )) || exit 2; exec nvidia-smi -pl "$arg" ;;
  nv-lock)   isint "$arg" && (( arg >= 300 && arg <= 4000 )) || exit 2; exec nvidia-smi -lgc "300,$arg" ;;
  nv-unlock) exec nvidia-smi -rgc ;;
  nv-power-default)
    d="$(nvidia-smi --query-gpu=power.default_limit --format=csv,noheader,nounits 2>/dev/null | head -1)"; d="${d%.*}"
    isint "$d" || exit 3; exec nvidia-smi -pl "$d" ;;
  amd-power)
    isint "$arg" && (( arg >= 10 && arg <= 600 )) || exit 2
    dev="$(amd_dev)" && h="$(amd_hw "$dev")" || exit 3
    echo $(( arg * 1000000 )) > "$h/power1_cap" ;;
  amd-power-default)
    dev="$(amd_dev)" && h="$(amd_hw "$dev")" || exit 3
    cat "$h/power1_cap_default" > "$h/power1_cap" ;;
  amd-clock)
    isint "$arg" && (( arg >= 200 && arg <= 4000 )) || exit 2
    dev="$(amd_dev)" || exit 3
    echo manual > "$dev/power_dpm_force_performance_level" && \
    echo "s 1 $arg" > "$dev/pp_od_clk_voltage" && echo c > "$dev/pp_od_clk_voltage" ;;
  amd-reset)
    dev="$(amd_dev)" || exit 3
    echo r > "$dev/pp_od_clk_voltage" 2>/dev/null; echo c > "$dev/pp_od_clk_voltage" 2>/dev/null
    echo high > "$dev/power_dpm_force_performance_level" ;;
  *) echo "uso: hkos-gpu-root nv-power|nv-lock|nv-unlock|nv-power-default|amd-power|amd-power-default|amd-clock|amd-reset [N]" >&2; exit 1 ;;
esac
TOOL_EOF

put 755 usr/local/bin/hkos-gpu <<'TOOL_EOF'
#!/usr/bin/env bash
# hkos-gpu - energia, clock e overclock da placa de vídeo (NVIDIA completo, AMD: energia e clock máximo)
# Sem argumentos abre o menu. Overclock pode travar o jogo ou o PC: aumente aos poucos.
DRM="${HKOS_DRM:-/sys/class/drm}"
R="${HKOS_GPU_ROOT:-/usr/local/bin/hkos-gpu-root}"
ROOT=("$R"); [[ $EUID -eq 0 ]] || ROOT=(sudo "$R")
CONF="${HKOS_GPU_CONF:-$HOME/.config/hkos-gpu.conf}"
PEND="${CONF%.conf}.pending"

vendor() {
  if grep -qs 0x10de "$DRM"/card*/device/vendor; then echo nvidia
  elif grep -qs 0x1002 "$DRM"/card*/device/vendor; then echo amd
  else echo none; fi
}
nvq() { nvidia-smi --query-gpu="$1" --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' '; }
int() { local v="${1%.*}"; [[ "$v" =~ ^[0-9]+$ ]] && echo "$v"; }
amd_dev() { local c; for c in "$DRM"/card*/device; do grep -qs 0x1002 "$c/vendor" && { echo "$c"; return 0; }; done; return 1; }
amd_hw() { ls -d "$(amd_dev)"/hwmon/hwmon* 2>/dev/null | head -1; }

cget() { [[ -f "$CONF" ]] && grep -m1 "^$1=" "$CONF" | cut -d= -f2 | tr -cd '0-9-'; }
cset() { # cset CHAVE VALOR (vazio apaga)
  mkdir -p "$(dirname "$CONF")"; touch "$CONF"
  sed -i "/^$1=/d" "$CONF"; [[ -n "${2:-}" ]] && echo "$1=$2" >> "$CONF"; return 0
}

# ---------- limites ----------
pw_min()  { case "$(vendor)" in nvidia) int "$(nvq power.min_limit)" ;; amd) echo $(( $(cat "$(amd_hw)/power1_cap_min") / 1000000 )) ;; esac; }
pw_max()  { case "$(vendor)" in nvidia) int "$(nvq power.max_limit)" ;; amd) echo $(( $(cat "$(amd_hw)/power1_cap_max") / 1000000 )) ;; esac; }
pw_def()  { case "$(vendor)" in nvidia) int "$(nvq power.default_limit)" ;; amd) echo $(( $(cat "$(amd_hw)/power1_cap_default") / 1000000 )) ;; esac; }
clk_max() { case "$(vendor)" in nvidia) int "$(nvq clocks.max.gr)" ;; esac; }

# ---------- ações ----------
set_power() {
  local w="$1" lo hi
  [[ "$w" =~ ^[0-9]+$ ]] || { echo "Digite um número em watts."; return 1; }
  lo="$(pw_min)"; hi="$(pw_max)"
  if [[ -n "$lo" && -n "$hi" ]] && (( w < lo || w > hi )); then echo "Esta placa aceita de $lo a $hi W."; return 1; fi
  case "$(vendor)" in
    nvidia) "${ROOT[@]}" nv-power "$w" >/dev/null ;;
    amd)    "${ROOT[@]}" amd-power "$w" ;;
    *) echo "Nenhuma GPU NVIDIA ou AMD encontrada."; return 1 ;;
  esac || { echo "Não consegui definir a energia."; return 1; }
  cset POWER "$w"
}
set_clock() { # MHz | off
  local m="$1"
  if [[ "$m" == off ]]; then
    case "$(vendor)" in nvidia) "${ROOT[@]}" nv-unlock >/dev/null ;; amd) "${ROOT[@]}" amd-reset ;; *) return 1 ;; esac || return 1
    cset CLOCK ""; return 0
  fi
  [[ "$m" =~ ^[0-9]+$ ]] || { echo "Digite um número em MHz."; return 1; }
  case "$(vendor)" in
    nvidia) "${ROOT[@]}" nv-lock "$m" >/dev/null ;;
    amd)    "${ROOT[@]}" amd-clock "$m" ;;
    *) echo "Nenhuma GPU NVIDIA ou AMD encontrada."; return 1 ;;
  esac || { echo "Não consegui limitar o clock."; return 1; }
  cset CLOCK "$m"
}
set_offset() { # core|mem N  (só NVIDIA, precisa do X e do Coolbits)
  local kind="$1" n="$2" a1 a2
  [[ "$(vendor)" == nvidia ]] || { echo "Offset de clock só existe aqui para NVIDIA."; return 1; }
  [[ "$n" =~ ^-?[0-9]+$ ]] || { echo "Digite um número (MHz, pode ser negativo)."; return 1; }
  if [[ "$kind" == core ]]; then
    (( n >= -300 && n <= 300 )) || { echo "Núcleo: use de -300 a 300."; return 1; }
    a1="GPUGraphicsClockOffsetAllPerformanceLevels"; a2="GPUGraphicsClockOffset[3]"
  else
    (( n >= -1000 && n <= 1500 )) || { echo "Memória: use de -1000 a 1500."; return 1; }
    a1="GPUMemoryTransferRateOffsetAllPerformanceLevels"; a2="GPUMemoryTransferRateOffset[3]"
  fi
  command -v nvidia-settings >/dev/null || { echo "nvidia-settings ausente."; return 1; }
  nvidia-settings -a "[gpu:0]/$a1=$n" >/dev/null 2>&1 || nvidia-settings -a "[gpu:0]/$a2=$n" >/dev/null 2>&1 \
    || { echo "Falhou. Precisa de X11 e Coolbits (reinicie o desktop após atualizar o HKOS)."; return 1; }
  cset "$( [[ $kind == core ]] && echo CORE || echo MEM )" "$n"
}
reset_hw() {
  case "$(vendor)" in
    nvidia) "${ROOT[@]}" nv-power-default >/dev/null 2>&1; "${ROOT[@]}" nv-unlock >/dev/null 2>&1
            nvidia-settings -a "[gpu:0]/GPUGraphicsClockOffsetAllPerformanceLevels=0" \
                            -a "[gpu:0]/GPUMemoryTransferRateOffsetAllPerformanceLevels=0" >/dev/null 2>&1 || true ;;
    amd)    "${ROOT[@]}" amd-power-default 2>/dev/null; "${ROOT[@]}" amd-reset 2>/dev/null ;;
  esac
  return 0
}
profile() { # padrao | desempenho | eficiente
  local d hi mc
  case "$1" in
    padrao)     reset_hw; rm -f "$CONF"; return 0 ;;
    desempenho) hi="$(pw_max)"; reset_hw; rm -f "$CONF"
                [[ -n "$hi" ]] && set_power "$hi"
                if [[ "$(vendor)" == nvidia ]]; then set_offset core 50; set_offset mem 300; fi ;;
    eficiente)  d="$(pw_def)"; mc="$(clk_max)"; reset_hw; rm -f "$CONF"
                [[ -n "$d" ]] && set_power $(( d * 80 / 100 ))
                [[ -n "$mc" ]] && set_clock $(( mc * 85 / 100 )) ;;
    *) echo "perfil: padrao | desempenho | eficiente"; return 1 ;;
  esac
}
apply_conf() {
  local v
  v="$(cget POWER)";  [[ -n "$v" ]] && set_power "$v"
  v="$(cget CLOCK)";  [[ -n "$v" ]] && set_clock "$v"
  v="$(cget CORE)";   [[ -n "$v" ]] && set_offset core "$v"
  v="$(cget MEM)";    [[ -n "$v" ]] && set_offset mem "$v"
  return 0
}
boot() { # chamado no login. Se o PC travou nos 2 primeiros minutos da última vez, não aplica de novo.
  [[ "$(cget BOOT)" == 1 ]] || return 0
  if [[ -f "$PEND" ]]; then
    rm -f "$PEND"; cset BOOT 0; reset_hw
    command -v notify-send >/dev/null && notify-send "HKOS GPU" "O perfil anterior não terminou bem e foi desligado. Reative em hkos-gpu."
    return 0
  fi
  touch "$PEND"; apply_conf; sleep "${HKOS_GPU_GUARD:-120}"; rm -f "$PEND"
}

status() {
  case "$(vendor)" in
    nvidia) nvidia-smi --query-gpu=name,temperature.gpu,power.draw,power.limit,clocks.gr,clocks.max.gr,clocks.mem,utilization.gpu \
              --format=csv,noheader 2>/dev/null | awk -F', ' '{printf "Placa: %s\nTemperatura: %s C\nEnergia: %s (limite %s)\nClock núcleo: %s (máx %s)\nClock memória: %s\nUso: %s\n", $1,$2,$3,$4,$5,$6,$7,$8}'
            echo "Ajustes salvos: energia=$(cget POWER) clock=$(cget CLOCK) núcleo=$(cget CORE) memória=$(cget MEM) ao-ligar=$(cget BOOT)" ;;
    amd)    local h; h="$(amd_hw)"
            echo "Placa AMD"; [[ -n "$h" ]] && echo "Temperatura: $(( $(cat "$h/temp1_input") / 1000 )) C" && echo "Limite de energia: $(( $(cat "$h/power1_cap") / 1000000 )) W"
            echo "Ajustes salvos: energia=$(cget POWER) clock=$(cget CLOCK) ao-ligar=$(cget BOOT)" ;;
    *) echo "Nenhuma GPU NVIDIA ou AMD encontrada." ;;
  esac
}

menu() {
  command -v dialog >/dev/null || { echo "dialog ausente"; exit 1; }
  local C V msg lo hi
  while true; do
    C="$(dialog --stdout --title "HKOS GPU ($(vendor))" --menu "Overclock pode travar o jogo ou o PC. Aumente aos poucos." 20 70 10 \
      1 "Ver situação da placa" \
      2 "Limite de energia (W)" \
      3 "Limitar o clock máximo (MHz)" \
      4 "Offset do clock do núcleo (NVIDIA)" \
      5 "Offset do clock da memória (NVIDIA)" \
      6 "Perfil Desempenho (energia máxima + overclock leve)" \
      7 "Perfil Eficiente (menos calor e barulho)" \
      8 "Perfil Padrão (volta tudo ao normal)" \
      9 "Aplicar ao ligar (liga/desliga)" \
      0 "Sair")" || exit 0
    msg=""
    case "$C" in
      1) dialog --msgbox "$(status)" 14 70; continue ;;
      2) lo="$(pw_min)"; hi="$(pw_max)"
         V="$(dialog --stdout --inputbox "Limite de energia em watts (${lo:-?} a ${hi:-?}):" 8 60)" || continue
         msg="$(set_power "$V" 2>&1)" && msg="Limite de energia: $V W." ;;
      3) V="$(dialog --stdout --inputbox "Clock máximo em MHz (ou 'off' para soltar). Máx da placa: $(clk_max):" 9 62)" || continue
         msg="$(set_clock "$V" 2>&1)" && msg="Clock máximo: $V." ;;
      4) V="$(dialog --stdout --inputbox "Offset do núcleo em MHz (-300 a 300). Comece com 25:" 8 62)" || continue
         msg="$(set_offset core "$V" 2>&1)" && msg="Offset do núcleo: $V MHz." ;;
      5) V="$(dialog --stdout --inputbox "Offset da memória em MHz (-1000 a 1500). Comece com 100:" 8 62)" || continue
         msg="$(set_offset mem "$V" 2>&1)" && msg="Offset da memória: $V MHz." ;;
      6) dialog --yesno "Aumenta a energia ao máximo e dá um overclock leve (núcleo +50, memória +300 na NVIDIA). Pode esquentar mais. Continuar?" 9 60 || continue
         msg="$(profile desempenho 2>&1)" && msg="Perfil Desempenho aplicado." ;;
      7) msg="$(profile eficiente 2>&1)" && msg="Perfil Eficiente aplicado." ;;
      8) msg="$(profile padrao 2>&1)" && msg="Tudo voltou ao padrão." ;;
      9) if [[ "$(cget BOOT)" == 1 ]]; then cset BOOT ""; msg="Não vai mais aplicar ao ligar."
         else cset BOOT 1; msg="Vai aplicar a cada login (só no HKOS instalado no disco). Se o PC travar nos 2 primeiros minutos, o perfil é desligado sozinho."; fi ;;
      0) exit 0 ;;
    esac
    dialog --msgbox "${msg:-Feito.}" 9 66
  done
}

case "${1:-}" in
  status)  status ;;
  power)   set_power "${2:-}" ;;
  clock)   set_clock "${2:-}" ;;
  core)    set_offset core "${2:-}" ;;
  mem)     set_offset mem "${2:-}" ;;
  profile) profile "${2:-}" ;;
  save)    cset BOOT "${2:-1}" ;;
  boot)    boot ;;
  reset)   profile padrao ;;
  *)       menu ;;
esac
TOOL_EOF

put 755 usr/local/bin/hkos-run <<'TOOL_EOF'
#!/usr/bin/env bash
# hkos-run - "Executar" (tecla Windows + R): digite o nome do programa
exec dmenu_run -b -fn 'Liberation Sans-11' -nb '#000000' -nf '#e6e6e6' -sb '#e6e6e6' -sf '#000000' -p 'Executar:'
TOOL_EOF
put 644 $SK/.config/dunst/dunstrc <<'EOF'
[global]
    monitor = 0
    follow = keyboard
    width = (0, 340)
    height = (0, 120)
    origin = bottom-right
    offset = (12, 48)
    transparency = 0
    frame_width = 1
    frame_color = "#3a3a3a"
    font = Liberation Sans 10
    padding = 10
    horizontal_padding = 12
    corner_radius = 0
    separator_height = 1
    markup = full
    format = "<b>%s</b>\n%b"
    icon_position = left
    max_icon_size = 40
    sticky_history = no
    mouse_left_click = close_current
    mouse_right_click = close_all

[urgency_low]
    background = "#000000"
    foreground = "#cccccc"
    timeout = 4

[urgency_normal]
    background = "#000000"
    foreground = "#ffffff"
    timeout = 6

[urgency_critical]
    background = "#000000"
    foreground = "#ffffff"
    frame_color = "#ff5555"
    timeout = 0
EOF
put 644 $SK/.config/pcmanfm/default/desktop-items-0.conf <<'EOF'
[*]
wallpaper_mode=crop
wallpaper_common=1
desktop_bg=#000000
desktop_fg=#ffffff
desktop_shadow=#000000
desktop_font=Liberation Sans 10
show_wm_menu=1
sort=name;ascending;
show_documents=0
show_trash=1
show_mounts=0
EOF
put 755 $SK/Desktop/Este-computador.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Este computador
Exec=hkos-explorer
Icon=computer
Terminal=false
EOF
put 755 $SK/Desktop/Steam.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Steam
Exec=steam
Icon=steam
Terminal=false
EOF
put 755 $SK/Desktop/Discord.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Discord
Exec=discord
Icon=discord
Terminal=false
EOF
put 755 $SK/Desktop/Firefox.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Firefox
Exec=firefox
Icon=firefox
Terminal=false
EOF
put 755 $SK/Desktop/Heroic.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Heroic
Exec=hkos-heroic
Icon=applications-games
Terminal=false
EOF
put 644 usr/share/applications/hkos-heroic.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Heroic Games Launcher
Comment=Epic, GOG e Amazon
Exec=hkos-heroic
Icon=applications-games
Terminal=false
Categories=Game;
EOF
put 644 etc/fonts/local.conf <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <!-- Visual parecido com o Windows: Arial/Courier equivalentes -->
  <alias><family>sans-serif</family><prefer><family>Liberation Sans</family></prefer></alias>
  <alias><family>serif</family><prefer><family>Liberation Serif</family></prefer></alias>
  <alias><family>monospace</family><prefer><family>Liberation Mono</family></prefer></alias>
</fontconfig>
EOF
put 644 $SK/.Xresources <<'EOF'
Xft.dpi: 96
xterm*faceName: DejaVu Sans Mono
xterm*faceSize: 11
xterm*background: #000000
xterm*foreground: #e6e6e6
xterm*cursorColor: #e6e6e6
xterm*scrollBar: false
xterm*saveLines: 5000
xterm*selectToClipboard: true
xterm*utf8: 1
EOF
put 755 $SK/.config/openbox/autostart <<'EOF'
xsetroot -cursor_name left_ptr &
WALL=/usr/share/wallpapers/HKOS/hkos.png
ULTRA=0; [ -f "$HOME/.config/hkos-ultra" ] && ULTRA=1
if [ "$ULTRA" = 1 ]; then
  xsetroot -solid '#000000' &
else
# Ícones na área de trabalho (Este computador, Lixeira...). Para desligar: touch ~/.config/hkos-no-desktop-icons
if [ -f "$WALL" ] && command -v pcmanfm >/dev/null 2>&1 && [ ! -f "$HOME/.config/hkos-no-desktop-icons" ]; then
  hkos-explorer --desktop &
  ( sleep 2; pcmanfm --set-wallpaper="$WALL" --wallpaper-mode=crop ) &
elif [ -f "$WALL" ]; then
  feh --no-fehbg --bg-fill "$WALL" &
else
  xsetroot -solid '#000000' &
fi
dunst &
tint2 &
nm-applet &
volumeicon &
fi
[ -f "$HOME/.config/hkos-fan-curve" ] && hkos-fan run &
[ -f "$HOME/.config/hkos-gpu.conf" ] && hkos-gpu boot &
# NVIDIA: PowerMizer em "preferir máximo desempenho" (ignorado em outras placas)
if command -v nvidia-settings >/dev/null 2>&1 && [ -e /dev/nvidiactl ]; then
  nvidia-settings -a "[gpu:0]/GpuPowerMizerMode=1" >/dev/null 2>&1 &
fi
# Modo ultraleve: só o Steam em tela cheia (Big Picture)
[ "$ULTRA" = 1 ] && steam -gamepadui >/dev/null 2>&1 &
EOF
put 644 $SK/.config/openbox/menu.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
<menu id="root-menu" label="HKOS">
  <item label="Explorador de arquivos"><action name="Execute"><command>hkos-explorer</command></action></item>
  <item label="Steam"><action name="Execute"><command>steam</command></action></item>
  <item label="Discord"><action name="Execute"><command>discord</command></action></item>
  <item label="Firefox"><action name="Execute"><command>firefox</command></action></item>
  <item label="Battle.net (Lutris)"><action name="Execute"><command>hkos-battlenet</command></action></item>
  <separator/>
  <item label="Terminal"><action name="Execute"><command>xterm</command></action></item>
  <item label="Volume"><action name="Execute"><command>pavucontrol</command></action></item>
  <separator/>
  <item label="Modo console (Steam em tela cheia)"><action name="Execute"><command>hkos-mode console</command></action></item>
  <item label="Modo ultraleve (só o Steam)"><action name="Execute"><command>hkos-mode ultra</command></action></item>
  <item label="Ajustes HKOS"><action name="Execute"><command>xterm -e sudo hkos-tweaks</command></action></item>
  <item label="Ventoinha da placa de vídeo"><action name="Execute"><command>xterm -e hkos-fan</command></action></item>
  <item label="GPU: energia e overclock"><action name="Execute"><command>xterm -e hkos-gpu</command></action></item>
  <item label="Heroic (Epic, GOG, Amazon)"><action name="Execute"><command>hkos-heroic</command></action></item>
  <item label="Instalar Proton-HKOS (otimizado)"><action name="Execute"><command>xterm -e hkos-proton-ge hkos</command></action></item>
  <item label="Instalar Proton-GE"><action name="Execute"><command>xterm -e hkos-proton-ge ge</command></action></item>
  <item label="Loja (instalar programas e drivers)"><action name="Execute"><command>xterm -e hkos-loja</command></action></item>
  <item label="Ajuda e comandos"><action name="Execute"><command>xterm -e hkos-ajuda</command></action></item>
  <item label="Informações do sistema"><action name="Execute"><command>xterm -e hkos-info</command></action></item>
  <separator/>
  <item label="Instalar HKOS no disco"><action name="Execute"><command>xterm -e sudo hkos-install</command></action></item>
  <separator/>
  <item label="Reiniciar"><action name="Execute"><command>systemctl reboot</command></action></item>
  <item label="Desligar"><action name="Execute"><command>systemctl poweroff</command></action></item>
  <item label="Sair da sessão"><action name="Exit"/></item>
</menu>
</openbox_menu>
EOF
put 644 $SK/.config/tint2/tint2rc <<'EOF'
# HKOS - barra estilo Windows (embaixo): atalhos | janelas | bandeja | relógio
rounded = 0
border_width = 0
background_color = #000000 100
border_color = #000000 0
background_color_hover = #000000 100
border_color_hover = #000000 0
background_color_pressed = #000000 100
border_color_pressed = #000000 0

rounded = 3
border_width = 0
background_color = #000000 100
border_color = #000000 0
background_color_hover = #141414 100
border_color_hover = #000000 0
background_color_pressed = #141414 100
border_color_pressed = #000000 0

rounded = 3
border_width = 1
background_color = #1c1c1c 100
border_color = #e6e6e6 60
background_color_hover = #262626 100
border_color_hover = #e6e6e6 60
background_color_pressed = #262626 100
border_color_pressed = #e6e6e6 60

panel_items = BLTSC
panel_size = 100% 36
panel_margin = 0 0
panel_padding = 4 3 4
panel_background_id = 1
panel_position = bottom center horizontal
panel_layer = top
panel_monitor = all
strut_policy = follow_size
autohide = 0

button = new
button_text = HKOS
button_font = Liberation Sans Bold 11
button_font_color = #ffffff 100
button_padding = 14 4 6
button_background_id = 2
button_tooltip = Menu Iniciar (Ctrl+Esc)
button_lclick_command = xdotool key ctrl+Escape

launcher_padding = 4 2 6
launcher_background_id = 0
launcher_icon_size = 26
launcher_item_app = /usr/share/applications/hkos-explorer.desktop
launcher_item_app = /usr/share/applications/firefox.desktop
launcher_item_app = /usr/share/applications/steam.desktop
launcher_item_app = /usr/share/applications/discord.desktop
launcher_item_app = /usr/share/applications/xterm.desktop

taskbar_mode = single_desktop
taskbar_padding = 2 2 4
taskbar_background_id = 0
taskbar_active_background_id = 0
task_text = 1
task_icon = 1
task_centered = 0
task_maximum_size = 180 32
task_padding = 6 3 6
task_background_id = 2
task_active_background_id = 3
task_urgent_background_id = 3
task_iconified_background_id = 2
task_font_color = #cccccc 100
task_active_font_color = #ffffff 100
task_iconified_font_color = #999999 100

systray_padding = 4 2 4
systray_background_id = 0
systray_sort = ascending
systray_icon_size = 20

time1_format = %H:%M
time2_format = %d/%m/%Y
time1_font = sans 10
time2_font = sans 8
clock_font_color = #e6e6e6 100
clock_padding = 8 2
clock_background_id = 0
tooltip_show_timeout = 0.5
EOF
for v in 3 4; do
  put 644 "etc/gtk-$v.0/settings.ini" <<'EOF'
[Settings]
gtk-enable-animations=false
gtk-application-prefer-dark-theme=true
gtk-icon-theme-name=Adwaita
gtk-cursor-theme-name=Adwaita
EOF
done
put 644 etc/firefox/policies/policies.json <<'EOF'
{
  "policies": {
    "DisableTelemetry": true,
    "DisableFirefoxStudies": true,
    "DisablePocket": true,
    "DontCheckDefaultBrowser": true,
    "OverrideFirstRunPage": "",
    "OverridePostUpdatePage": "",
    "UserMessaging": {
      "WhatsNew": false,
      "ExtensionRecommendations": false,
      "FeatureRecommendations": false,
      "UrlbarInterventions": false,
      "SkipOnboarding": true
    },
    "Preferences": {
      "media.ffmpeg.vaapi.enabled": { "Value": true, "Status": "default" },
      "ui.systemUsesDarkTheme": { "Value": 1, "Status": "default" },
      "layout.css.prefers-color-scheme.content-override": { "Value": 0, "Status": "default" },
      "browser.tabs.unloadOnLowMemory": { "Value": true, "Status": "default" },
      "dom.ipc.processCount": { "Value": 4, "Status": "default" },
      "browser.sessionstore.interval": { "Value": 60000, "Status": "default" },
      "media.hardware-video-decoding.force-enabled": { "Value": true, "Status": "default" }
    }
  }
}
EOF

###############################################################################
# 6) SISTEMA: logs, timeouts, CPU, agendador, rede, módulos, GameMode, sysctl
###############################################################################
put 644 etc/systemd/journald.conf.d/gameos.conf <<'EOF'
[Journal]
SystemMaxUse=50M
RuntimeMaxUse=50M
ForwardToSyslog=no
EOF
put 644 etc/systemd/coredump.conf.d/gameos.conf <<'EOF'
[Coredump]
Storage=none
ProcessSizeMax=0
EOF
put 644 etc/systemd/system.conf.d/gameos.conf <<'EOF'
[Manager]
DefaultTimeoutStopSec=10s
DefaultLimitNOFILE=1024:1048576
EOF
put 644 etc/tmpfiles.d/gameos-cpu.conf <<'EOF'
# CPU em desempenho, discos sem economia de energia, THP só sob demanda
w /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor - - - - performance
w /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference - - - - performance
w /sys/class/scsi_host/host*/link_power_management_policy - - - - max_performance
w /sys/kernel/mm/transparent_hugepage/defrag - - - - defer+madvise
w /sys/kernel/mm/transparent_hugepage/enabled - - - - madvise
EOF
put 644 etc/tmpfiles.d/gameos-power.conf <<'EOF'
# HKOS - perfil MÁXIMO: nada de economia de energia
w /sys/devices/system/cpu/intel_pstate/no_turbo - - - - 0
w /sys/devices/system/cpu/intel_pstate/min_perf_pct - - - - 100
w /sys/devices/system/cpu/cpufreq/boost - - - - 1
w /sys/bus/pci/devices/*/power/control - - - - on
w /sys/class/drm/card*/device/power_dpm_force_performance_level - - - - high
EOF
put 644 usr/share/gameos/power-max.conf <<'EOF'
# HKOS - perfil MÁXIMO: nada de economia de energia
w /sys/devices/system/cpu/intel_pstate/no_turbo - - - - 0
w /sys/devices/system/cpu/intel_pstate/min_perf_pct - - - - 100
w /sys/devices/system/cpu/cpufreq/boost - - - - 1
w /sys/bus/pci/devices/*/power/control - - - - on
w /sys/class/drm/card*/device/power_dpm_force_performance_level - - - - high
EOF
put 644 etc/modprobe.d/gameos-audio.conf <<'EOF'
options snd_hda_intel power_save=0 power_save_controller=N
options snd_ac97_codec power_save=0
EOF
put 644 etc/X11/xorg.conf.d/20-nvidia-coolbits.conf <<'EOF'
# Libera ventoinha (4) e overclock (8) da NVIDIA (só casa com GPU NVIDIA)
Section "OutputClass"
    Identifier "hkos-nvidia-coolbits"
    MatchDriver "nvidia-drm"
    Driver "nvidia"
    Option "Coolbits" "12"
EndSection
EOF
put 644 etc/udev/rules.d/62-hkos-cpu-latency.rules <<'EOF'
# hkos-game --lowlat: permite segurar a CPU fora dos estados de sono profundo durante o jogo
KERNEL=="cpu_dma_latency", MODE="0666"
EOF
put 440 etc/sudoers.d/20-hkos-gpu <<'EOF'
%wheel ALL=(root) NOPASSWD: /usr/local/bin/hkos-gpu-root, /usr/local/bin/hkos-game-root
EOF
put 644 etc/default/scx <<'EOF'
# Agendador sched_ext (como CachyOS/Bazzite): LAVD, feito para jogos e baixa latência
SCX_SCHEDULER=scx_lavd
SCX_FLAGS='--performance'
EOF
put 644 etc/NetworkManager/conf.d/20-hkos.conf <<'EOF'
[connection]
wifi.powersave=2

[connectivity]
enabled=false
EOF
put 644 etc/modules-load.d/gameos.conf <<'EOF'
# BBR (rede) e NTSYNC (sincronização rápida do Wine/Proton)
tcp_bbr
ntsync
EOF
put 644 etc/gamemode.ini <<'EOF'
[general]
desiredgov=performance
softrealtime=auto
renice=10
inhibit_screensaver=1
ioprio=0
disable_splitlock=1

[gpu]
apply_gpu_optimisations=accept-responsibility
gpu_device=0
nv_powermizer_mode=1
amd_performance_level=high
EOF
put 644 etc/environment <<'EOF'
__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1
MESA_SHADER_CACHE_MAX_SIZE=10G
PROTON_USE_NTSYNC=1
WINEDEBUG=-all
DXVK_LOG_LEVEL=none
VKD3D_DEBUG=none
VKD3D_SHADER_DEBUG=none
EOF
put 644 etc/X11/xorg.conf.d/30-hkos-mouse.conf <<'EOF'
# Mouse sem aceleração (mira consistente nos jogos)
Section "InputClass"
    Identifier "hkos-mouse-flat"
    MatchIsPointer "on"
    MatchDriver "libinput"
    Option "AccelProfile" "flat"
    Option "AccelSpeed" "0"
EndSection
EOF
put 644 etc/sysctl.d/99-gameos.conf <<'EOF'
# HKOS - memória, agendador e rede para jogos
vm.swappiness = 150
vm.page-cluster = 0
vm.vfs_cache_pressure = 50
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.compaction_proactiveness = 0
vm.dirty_bytes = 268435456
vm.dirty_background_bytes = 67108864
vm.dirty_writeback_centisecs = 1500
vm.max_map_count = 2147483642

kernel.nmi_watchdog = 0
kernel.numa_balancing = 0
vm.stat_interval = 10
kernel.split_lock_mitigate = 0
kernel.sched_autogroup_enabled = 1
kernel.printk = 3 3 3 3

fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024

net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 16384
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_timestamps = 0
vm.zone_reclaim_mode = 0
fs.aio-max-nr = 1048576
EOF

put 644 etc/udev/rules.d/60-ioschedulers.rules <<'EOF'
# NVMe: sem escalonador; SSD SATA: mq-deadline; HDD: bfq
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none"
ACTION=="add|change", KERNEL=="sd[a-z]|mmcblk[0-9]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
EOF
put 644 etc/udev/rules.d/61-hkos-block.rules <<'EOF'
# Discos: sem entropia, conclusão de I/O no mesmo núcleo, leitura antecipada por tipo
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*|sd[a-z]|mmcblk[0-9]*", ATTR{queue/add_random}="0", ATTR{queue/rq_affinity}="2"
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/read_ahead_kb}="1024"
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*|sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/read_ahead_kb}="256"
EOF
put 644 etc/systemd/zram-generator.conf.d/gameos.conf <<'EOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = lz4
swap-priority = 100
fs-type = swap
EOF
put 644 etc/security/limits.d/10-gameos.conf <<'EOF'
*       soft    nofile  524288
*       hard    nofile  1048576
@audio  -       rtprio  95
@audio  -       memlock unlimited
EOF
put 644 etc/modprobe.d/gameos.conf <<'EOF'
# NVIDIA: modo DRM e sem zerar memória de sistema a cada alocação (igual ao CachyOS)
options nvidia_drm modeset=1 fbdev=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_InitializeSystemMemoryAllocations=0
blacklist iTCO_wdt
blacklist sp5100_tco
EOF
put 644 etc/X11/xorg.conf.d/40-hkos-serverflags.conf <<'EOF'
Section "ServerFlags"
    Option "BlankTime" "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime" "0"
EndSection
EOF
# Serviços e timers que só gastam CPU/disco em segundo plano
for u in man-db.timer shadow.timer archlinux-keyring-wkd-sync.timer systemd-journald-audit.socket NetworkManager-wait-online.service; do
  mkdir -p "$AIROOT/etc/systemd/system"; ln -sf /dev/null "$AIROOT/etc/systemd/system/$u"
done

# Arquivos que o instalador copia para o sistema instalado
SHIPPED=(
  etc/sysctl.d/99-gameos.conf
  etc/udev/rules.d/60-ioschedulers.rules
  etc/udev/rules.d/61-hkos-block.rules
  etc/X11/xorg.conf.d/40-hkos-serverflags.conf
  etc/systemd/zram-generator.conf.d/gameos.conf
  etc/security/limits.d/10-gameos.conf
  etc/modprobe.d/gameos.conf
  etc/modules-load.d/gameos.conf
  etc/systemd/journald.conf.d/gameos.conf
  etc/systemd/coredump.conf.d/gameos.conf
  etc/systemd/system.conf.d/gameos.conf
  etc/tmpfiles.d/gameos-cpu.conf
  etc/tmpfiles.d/gameos-power.conf
  usr/share/gameos/power-max.conf
  etc/modprobe.d/gameos-audio.conf
  usr/share/themes/HKOS/openbox-3/themerc
  etc/default/scx
  etc/NetworkManager/conf.d/20-hkos.conf
  etc/gamemode.ini
  etc/environment
  etc/gtk-3.0/settings.ini etc/gtk-4.0/settings.ini
  etc/firefox/policies/policies.json
  etc/vconsole.conf
  etc/X11/xorg.conf.d/00-keyboard.conf
  etc/X11/xorg.conf.d/20-nvidia-coolbits.conf
  etc/sudoers.d/20-hkos-gpu
  etc/udev/rules.d/62-hkos-cpu-latency.rules
  etc/X11/xorg.conf.d/30-hkos-mouse.conf
  etc/os-release etc/motd
  usr/share/applications/hkos-explorer.desktop
  usr/share/applications/hkos-heroic.desktop
  usr/share/hkos/keybinds.xml
  etc/fonts/local.conf
  usr/share/hkos/ajuda.txt
)
[[ "$HAS_WALL" == 1 ]] && SHIPPED+=("$WALL")
mkdir -p "$AIROOT/usr/share/gameos"
printf '%s\n' "${SHIPPED[@]}" > "$AIROOT/usr/share/gameos/files.txt"
cp "$HERE/packages.extra" "$AIROOT/usr/share/gameos/packages.txt"
if [[ "$KERNEL" != linux-zen ]]; then
  sed -i -e "s/^linux-zen\$/$KERNEL/" -e "s/^linux-zen-headers\$/$KERNEL-headers/" "$AIROOT/usr/share/gameos/packages.txt"
  mkdir -p "$AIROOT/usr/share/gameos/repo"
  [[ "${DRYRUN:-0}" == 1 ]] || cp -L "$KREPO"/* "$AIROOT/usr/share/gameos/repo/"
fi

###############################################################################
# 7) FERRAMENTAS HKOS: instalador, modo console, ajustes, Proton-GE, diagnóstico
###############################################################################
put 755 usr/local/bin/hkos-mode <<'TOOL_EOF'
#!/usr/bin/env bash
# hkos-mode console | console-always | ultra | desktop
# console: abre o Steam em tela cheia (Gamescope, sem desktop) no próximo login.
# ultra:   só o Steam em tela cheia: sem ícones, barra, notificações e bandeja (o mais leve).
F="$HOME/.config/hkos-console"
U="$HOME/.config/hkos-ultra"
mkdir -p "$(dirname "$F")"
case "${1:-}" in
  console)        echo once > "$F" ;;
  console-always) echo always > "$F" ;;
  ultra)          touch "$U"; echo "Modo ultraleve ativado. Saindo do desktop..."
                  [[ -n "${DISPLAY:-}" ]] && openbox --exit; exit 0 ;;
  desktop)        was=0; [[ -f "$U" ]] && was=1; rm -f "$F" "$U"; echo "Modo desktop ativado."
                  (( was )) && [[ -n "${DISPLAY:-}" ]] && openbox --exit; exit 0 ;;
  *) echo "uso: hkos-mode console | console-always | ultra | desktop"; exit 1 ;;
esac
command -v gamescope >/dev/null || echo "Aviso: o Gamescope não está instalado (hkos-loja). Sem ele o login abre o desktop normal."
echo "Modo console ativado. Saindo do desktop..."
[[ -n "${DISPLAY:-}" ]] && openbox --exit
TOOL_EOF

put 755 usr/local/bin/hkos-proton-ge <<'TOOL_EOF'
#!/usr/bin/env bash
# hkos-proton-ge [hkos|ge|cachyos] - baixa o Proton mais recente para o Steam (precisa de internet).
#   hkos     Proton-HKOS: base Proton-CachyOS (ou GE se faltar) + ajustes de FPS/latência do HKOS  (padrão)
#   ge       Proton-GE puro (GloriousEggroll)
#   cachyos  Proton-CachyOS puro (usa a versão x86-64-v3 se a CPU tiver AVX2)
set -euo pipefail
WHICH="${1:-hkos}"
DEST="${HKOS_PROTON_DIR:-$HOME/.local/share/Steam/compatibilitytools.d}"
mkdir -p "$DEST"
GE_API="https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest"
CX_API="https://api.github.com/repos/CachyOS/proton-cachyos/releases/latest"
if grep -qw avx2 /proc/cpuinfo 2>/dev/null; then CX_PATS=('x86_64_v3\.tar\.xz' 'x86_64\.tar\.xz'); else CX_PATS=('x86_64\.tar\.xz'); fi

find_url() { # api padrões... -> URL do download
  local api="$1"; shift
  local json links pat url=""
  json="$(curl -fsSL "$api" 2>/dev/null || true)"
  links="$(grep -o '"browser_download_url": *"[^"]*"' <<<"$json" | cut -d'"' -f4 || true)"
  for pat in "$@"; do
    url="$(grep -E "${pat}\$" <<<"$links" | head -1 || true)"
    [[ -n "$url" ]] && break
  done
  printf '%s' "$url"
}
fetch() { # URL -> extrai em $1 (pasta vazia) e imprime o nome da pasta do Proton
  local url="$1" tmp="$2"
  echo "Baixando: $url" >&2
  case "$url" in
    *.tar.xz) curl -fL --progress-bar "$url" | tar -xJ -C "$tmp" ;;
    *)        curl -fL --progress-bar "$url" | tar -xz -C "$tmp" ;;
  esac
  ls -1 "$tmp" | head -1
}
hkos_tune() { # aplica os ajustes do HKOS dentro da pasta do Proton
  local dir="$1" conf="$HOME/.config/hkos/dxvk.conf"
  mkdir -p "$(dirname "$conf")"
  cat > "$conf" <<'DXVK'
# HKOS: menos fila de quadros = menos latência de entrada
dxgi.maxFrameLatency = 1
d3d9.maxFrameLatency = 1
dxgi.syncInterval = -1
DXVK
  cat > "$dir/user_settings.py" <<UEOF
# Ajustes HKOS (Proton-HKOS). Apague este arquivo para voltar ao padrão do Proton.
user_settings = {
    "PROTON_USE_NTSYNC": "1",
    "PROTON_ENABLE_NVAPI": "1",
    "PROTON_FORCE_LARGE_ADDRESS_AWARE": "1",
    "WINEDEBUG": "-all",
    "PROTON_LOG": "0",
    "DXVK_LOG_LEVEL": "none",
    "VKD3D_DEBUG": "none",
    "VKD3D_SHADER_DEBUG": "none",
    "DXVK_CONFIG_FILE": "$conf",
    "__GL_SHADER_DISK_CACHE_SKIP_CLEANUP": "1",
    "__GL_SHADER_DISK_CACHE_SIZE": "10737418240",
}
UEOF
  if [[ -f "$dir/compatibilitytool.vdf" ]]; then
    sed -i -E 's/("display_name"[[:space:]]*)"[^"]*"/\1"HKOS Proton"/' "$dir/compatibilitytool.vdf"
  fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
case "$WHICH" in
  ge)      NAME="Proton-GE"
           URL="$(find_url "$GE_API" '\.tar\.gz')" ;;
  cachyos) NAME="Proton-CachyOS"
           URL="$(find_url "$CX_API" "${CX_PATS[@]}")" ;;
  hkos)    NAME="HKOS Proton"
           echo "Buscando a base (Proton-CachyOS)..."
           URL="$(find_url "$CX_API" "${CX_PATS[@]}")"
           [[ -n "$URL" ]] || { echo "CachyOS indisponível; usando o Proton-GE como base."; URL="$(find_url "$GE_API" '\.tar\.gz')"; } ;;
  *) echo "uso: hkos-proton-ge [hkos|ge|cachyos]"; exit 1 ;;
esac
if [[ -z "$URL" ]]; then
  echo "Não consegui achar o download do $NAME (sem internet ou o projeto mudou o nome dos arquivos)."
  read -rp "Enter para fechar..." _; exit 1
fi
FOLDER="$(fetch "$URL" "$TMP")"
[[ -n "$FOLDER" && -d "$TMP/$FOLDER" ]] || { echo "Falha ao extrair."; read -rp "Enter para fechar..." _; exit 1; }
if [[ "$WHICH" == hkos ]]; then
  hkos_tune "$TMP/$FOLDER"
  FINAL="HKOS-Proton"
else
  FINAL="$FOLDER"
fi
rm -rf "$DEST/$FINAL"; mv "$TMP/$FOLDER" "$DEST/$FINAL"
echo
echo "Pronto: $FINAL. Reinicie o Steam; nas propriedades do jogo, em Compatibilidade, escolha o $NAME."
read -rp "Enter para fechar..." _
TOOL_EOF

put 755 usr/local/bin/hkos-heroic <<'TOOL_EOF'
#!/usr/bin/env bash
# hkos-heroic - instala (na 1ª vez) e abre o Heroic Games Launcher (Epic, GOG, Amazon).
# O pacote do Heroic só existe no AUR; aqui baixa-se a versão oficial do GitHub (.tar.xz).
DIR="${HKOS_HEROIC_DIR:-$HOME/.local/opt/heroic}"
BIN="$DIR/heroic"
API="${HKOS_HEROIC_API:-https://api.github.com/repos/Heroic-Games-Launcher/HeroicGamesLauncher/releases/latest}"

install_heroic() {
  command -v curl >/dev/null || { echo "curl ausente."; return 1; }
  local free; free="$(df -Pm "$HOME" 2>/dev/null | awk 'NR==2{print $4}')"
  if [[ "$free" =~ ^[0-9]+$ ]] && (( free < 1200 )); then
    echo "Pouco espaço livre (${free} MB). O Heroic precisa de uns 1,2 GB."
    echo "No modo live (pendrive) a memória é o limite: instale o HKOS no disco."
    read -rp "Continuar mesmo assim? [s/N] " r; [[ "$r" =~ ^[sS]$ ]] || return 1
  fi
  echo "Buscando a versão mais recente do Heroic..."
  local url tmp d
  url="$(curl -fsSL "$API" | grep -o '"browser_download_url": *"[^"]*\.tar\.xz"' \
        | cut -d'"' -f4 | grep -iv 'arm\|aarch' | head -1 || true)"
  [[ -n "$url" ]] || { echo "Não achei o download (sem internet?)."; return 1; }
  tmp="$(mktemp -d)" || return 1
  echo "Baixando: $url"
  if ! curl -fL --progress-bar "$url" -o "$tmp/heroic.tar.xz"; then echo "Falha no download."; rm -rf "$tmp"; return 1; fi
  mkdir "$tmp/x"
  if ! tar -xJf "$tmp/heroic.tar.xz" -C "$tmp/x"; then echo "Arquivo corrompido."; rm -rf "$tmp"; return 1; fi
  d="$(find "$tmp/x" -maxdepth 2 -name heroic -type f | head -1)"
  [[ -n "$d" ]] || { echo "Arquivo inesperado: executável não encontrado."; rm -rf "$tmp"; return 1; }
  rm -rf "$DIR"; mkdir -p "$(dirname "$DIR")"
  mv "$(dirname "$d")" "$DIR"; chmod +x "$BIN"
  rm -rf "$tmp"
  echo "Heroic instalado."
}

launch() {
  local pid
  "$BIN" >"$HOME/.heroic.log" 2>&1 & pid=$!
  sleep 6
  if ! kill -0 "$pid" 2>/dev/null; then   # fechou sozinho: tenta sem o sandbox do Chromium
    "$BIN" --no-sandbox >"$HOME/.heroic.log" 2>&1 &
  fi
  disown 2>/dev/null || true
}

case "${1:-}" in
  install) install_heroic; read -rp "Enter para fechar..." _ ;;
  *)
    if [[ ! -x "$BIN" ]]; then
      if [[ -t 0 ]]; then install_heroic || { read -rp "Enter para fechar..." _; exit 1; }
      else xterm -e "$0" install; fi
    fi
    [[ -x "$BIN" ]] && launch ;;
esac
TOOL_EOF

put 755 usr/local/bin/hkos-explorer <<'TOOL_EOF'
#!/usr/bin/env bash
# hkos-explorer - explorador de arquivos leve (PCManFM) com a cara do HKOS.
# Barra lateral: Downloads, Vídeos, Documentos, Imagens, Disco local e os discos/pendrives.
command -v pcmanfm >/dev/null || { echo "pcmanfm não está instalado."; exit 1; }
CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
mkdir -p "$HOME/Downloads" "$HOME/Videos" "$HOME/Documents" "$HOME/Pictures" \
         "$CFG/pcmanfm/default" "$CFG/libfm" "$CFG/gtk-3.0"

[[ -f "$CFG/pcmanfm/default/pcmanfm.conf" ]] || cat > "$CFG/pcmanfm/default/pcmanfm.conf" <<'EOF'
[config]
bm_open_method=0

[volume]
mount_on_startup=1
mount_removable=1
autorun=0

[ui]
always_show_tabs=0
max_tab_chars=32
win_width=1000
win_height=620
splitter_pos=200
side_pane_mode=places
view_mode=list
show_hidden=0
sort=name;ascending;
toolbar=navigation;
show_statusbar=1
pathbar_mode_buttons=0
EOF

[[ -f "$CFG/libfm/libfm.conf" ]] || cat > "$CFG/libfm/libfm.conf" <<'EOF'
[config]
single_click=0
use_trash=1
confirm_del=1
quick_exec=1
terminal=xterm -e %s
thumbnail_local=1
thumbnail_max=2048

[ui]
big_icon_size=48
small_icon_size=20
pane_icon_size=20
thumbnail_size=128
EOF

# Barra lateral: refeita sempre (o caminho da home muda de usuário para usuário)
{
  printf 'file://%s Downloads\n' "$HOME/Downloads"
  printf 'file://%s Vídeos\n' "$HOME/Videos"
  printf 'file://%s Documentos\n' "$HOME/Documents"
  printf 'file://%s Imagens\n' "$HOME/Pictures"
  printf 'file:/// Disco local\n'
} | tee "$CFG/gtk-3.0/bookmarks" > "$HOME/.gtk-bookmarks"

exec pcmanfm "${@:-$HOME}"
TOOL_EOF

put 644 usr/share/applications/hkos-explorer.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Explorador de arquivos
Comment=Downloads, vídeos e discos
Exec=hkos-explorer
Icon=system-file-manager
Terminal=false
Categories=System;FileManager;
EOF



put 755 usr/local/bin/hkos-info <<'TOOL_EOF'
#!/usr/bin/env bash
# Diagnóstico do sistema. Salva em ~/hkos-info.txt (útil para pedir ajuda).
OUT="$HOME/hkos-info.txt"
{
echo "== HKOS info $(date) =="
echo "-- Kernel";   uname -r; cat /proc/cmdline
echo "-- CPU";      lscpu | grep -E 'Model name|^CPU\(s\)'
echo "governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
echo "-- GPU";      (lspci -k | grep -EA3 'VGA|3D|Display') 2>/dev/null || echo "lspci indisponível"
echo "-- Módulos";  lsmod | grep -E 'nvidia|ntsync|amdgpu|i915|xe|nouveau' || echo "nenhum módulo de vídeo carregado"
echo "ntsync: $(ls /dev/ntsync 2>&1)"
echo "-- Agendador"; echo "scx.service: $(systemctl is-active scx.service 2>&1)"; cat /sys/kernel/sched_ext/state 2>/dev/null || true
echo "-- Memória";  free -h; zramctl 2>/dev/null || true
echo "-- Tempo de boot"; systemd-analyze 2>/dev/null; systemd-analyze blame 2>/dev/null | head -12
echo "-- Serviços com falha"; systemctl --failed --no-legend
echo "-- Erros do boot"; journalctl -b -p 3 --no-pager 2>/dev/null | tail -40
echo "-- startx.log"; tail -20 "$HOME/.startx.log" 2>/dev/null
echo "-- Xorg (EE)"; grep -h '(EE)' "$HOME"/.local/share/xorg/Xorg.*.log 2>/dev/null | tail -20
} 2>&1 | tee "$OUT"
echo; echo "Salvo em $OUT"
read -rp "Enter para fechar..." _
TOOL_EOF

put 755 usr/local/bin/hkos-fan <<'TOOL_EOF'
#!/usr/bin/env bash
# hkos-fan [set N | auto | run | temp]  - ventoinha da placa de vídeo (NVIDIA e AMD)
# Sem argumentos abre o menu. Mínimo de 30% por segurança.
DRM="${HKOS_DRM:-/sys/class/drm}"
SUDO=(); [[ $EUID -eq 0 ]] || SUDO=(sudo)
FLAG="$HOME/.config/hkos-fan-curve"

vendor() {
  if grep -qs 0x10de "$DRM"/card*/device/vendor; then echo nvidia
  elif grep -qs 0x1002 "$DRM"/card*/device/vendor; then echo amd
  else echo none; fi
}
amd_dir() {
  local d
  for d in "$DRM"/card*/device/hwmon/hwmon*; do
    [[ -e "$d/pwm1" ]] && { echo "$d"; return 0; }
  done
  return 1
}
gpu_temp() {
  local d
  case "$(vendor)" in
    nvidia) nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 ;;
    amd)    d="$(amd_dir)" && echo $(( $(cat "$d/temp1_input") / 1000 )) ;;
  esac
}
fan_set() { # 30..100
  local p="$1" d
  if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 30 || p > 100 )); then echo "Use um valor de 30 a 100."; return 1; fi
  case "$(vendor)" in
    nvidia)
      nvidia-settings -a "[gpu:0]/GPUFanControlState=1" -a "[fan:0]/GPUTargetFanSpeed=$p" >/dev/null 2>&1 \
        || { echo "Falhou. Precisa de X11 e do Coolbits (reinicie o desktop depois de instalar)."; return 1; }
      nvidia-settings -a "[fan:1]/GPUTargetFanSpeed=$p" >/dev/null 2>&1 || true ;;
    amd)
      d="$(amd_dir)" || { echo "Esta placa AMD não expõe controle manual (pwm1)."; return 1; }
      echo 1 | "${SUDO[@]}" tee "$d/pwm1_enable" >/dev/null || return 1
      echo $(( p * 255 / 100 )) | "${SUDO[@]}" tee "$d/pwm1" >/dev/null ;;
    *) echo "Nenhuma GPU NVIDIA ou AMD encontrada."; return 1 ;;
  esac
}
fan_auto() {
  local d
  case "$(vendor)" in
    nvidia) nvidia-settings -a "[gpu:0]/GPUFanControlState=0" >/dev/null 2>&1 ;;
    amd)    d="$(amd_dir)" && echo 2 | "${SUDO[@]}" tee "$d/pwm1_enable" >/dev/null ;;
  esac
}
curve_loop() { # só NVIDIA; volta ao automático ao sair
  trap 'fan_auto' EXIT
  trap 'exit 0' INT TERM
  local t s last=""
  while true; do
    t="$(gpu_temp)"
    if [[ "$t" =~ ^[0-9]+$ ]]; then
      if   (( t >= 80 )); then s=100
      elif (( t >= 70 )); then s=85
      elif (( t >= 60 )); then s=70
      elif (( t >= 50 )); then s=55
      elif (( t >= 40 )); then s=40
      else s=30; fi
      if [[ "$s" != "$last" ]]; then fan_set "$s" >/dev/null 2>&1 && last="$s"; fi
    fi
    sleep "${HKOS_FAN_INTERVAL:-3}"
  done
}
menu() {
  command -v dialog >/dev/null || { echo "dialog ausente"; exit 1; }
  local C t
  while true; do
    t="$(gpu_temp)"
    C="$(dialog --stdout --title "Ventoinha da GPU ($(vendor), ${t:-?}°C)" \
      --menu "Velocidade fixa baixa pode superaquecer a placa. Fique de olho na temperatura." 22 72 11 \
      100 "100% (máximo)" 80 "80%" 70 "70%" 60 "60%" 50 "50%" 40 "40%" 30 "30% (mínimo)" \
      auto "Automático (padrão da placa)" \
      curve "Curva automática ao ligar o PC (NVIDIA)" \
      nocurve "Desligar a curva automática" \
      sair "Sair")" || exit 0
    case "$C" in
      auto)    fan_auto && dialog --msgbox "Ventoinha no automático." 6 40 ;;
      curve)   if [[ "$(vendor)" != nvidia ]]; then dialog --msgbox "A curva automática é só para NVIDIA. Use um valor fixo ou o automático." 7 56
               else mkdir -p "$(dirname "$FLAG")"; touch "$FLAG"; (setsid "$0" run >/dev/null 2>&1 &)
                    dialog --msgbox "Curva ligada agora e a cada login:\n40C=40% 50C=55% 60C=70% 70C=85% 80C+=100%" 8 56; fi ;;
      nocurve) rm -f "$FLAG"; pkill -f 'hkos-fan run' 2>/dev/null; fan_auto; dialog --msgbox "Curva desligada." 6 40 ;;
      sair)    exit 0 ;;
      *)       if fan_set "$C"; then dialog --msgbox "Ventoinha em $C%." 6 40
               else dialog --msgbox "Não consegui ajustar. Veja a mensagem no terminal." 6 56; fi ;;
    esac
  done
}

case "${1:-}" in
  set)  fan_set "${2:-}" ;;
  auto) fan_auto ;;
  run)  curve_loop ;;
  temp) gpu_temp ;;
  *)    menu ;;
esac
TOOL_EOF

put 644 usr/share/hkos/ajuda.txt <<'HELP_EOF'
================================================================
  HKOS - AJUDA E COMANDOS         (setas/PageUp/PageDown, q sai)
  Dica: dentro desta tela, digite /palavra para procurar.
================================================================

1) USO BASICO
  Botao direito na area de trabalho ..... menu principal
  Botao do meio na area de trabalho ..... lista de janelas
  Tecla Windows + E ..................... explorador de arquivos
  Tecla Windows + R ..................... executar um programa pelo nome
  Ctrl + Esc / botao HKOS ............... menu Iniciar
  Windows + setas ....................... cima maximiza, baixo minimiza,
                                          esquerda/direita metade da tela
  Icones da area de trabalho: para desligar rode
    touch ~/.config/hkos-no-desktop-icons   (e faca login de novo)
  Alt+Tab ............................... trocar de janela
  Alt+F4 ................................ fechar janela
  Terminal: menu > Terminal (ou barra de baixo)

2) FERRAMENTAS DO HKOS (no menu ou digitando o nome)
  hkos-loja ............ instalar programas e drivers (menu pronto)
  hkos-ajuda ........... esta tela
  sudo hkos-tweaks ..... perfil de desempenho, agendador, mitigacoes
  hkos-fan ............. ventoinha da placa de video
  hkos-gpu ............. energia, clock e overclock da placa de video
  hkos-game ............ roda o jogo com ajustes de FPS/latencia (Steam: hkos-game %command%)
  hkos-bench ........... mede FPS medio, 1% low e 0,1% low (hkos-bench -t 120 %command%)
  hkos-info ............ relatorio do sistema (salva ~/hkos-info.txt)
  hkos-proton-ge ....... baixa o Proton-GE para o Steam
  hkos-heroic .......... instala e abre o Heroic (Epic, GOG, Amazon)
  hkos-explorer ........ explorador de arquivos (atalho: tecla Windows + E)
  hkos-mode console .... Steam em tela cheia no proximo login
  hkos-mode ultra ...... so o Steam em tela cheia (sem barra, icones e avisos)
  hkos-mode desktop .... volta ao modo desktop
  sudo hkos-install .... instalar o HKOS no disco (APAGA o disco). Pergunta o sistema
                         de arquivos, o firmware e os programas extras.

3) INSTALAR, PESQUISAR E REMOVER PROGRAMAS (pacman)
  sudo pacman -Syu .................. atualizar o sistema inteiro
  pacman -Ss nome ................... pesquisar um programa
  sudo pacman -S nome ............... instalar
  sudo pacman -Rns nome ............. remover (com dependencias)
  pacman -Qs nome ................... ver se esta instalado
  pacman -Qi nome ................... detalhes de um pacote instalado
  Exemplo: sudo pacman -S vlc obs-studio qbittorrent
  AVISO: no modo live (pendrive) o que voce instala some ao reiniciar
  e o espaco e pequeno. Programas grandes: instale o HKOS no disco.

4) DRIVERS
  NVIDIA (ja vem pronto; GTX 16xx / RTX 20xx ou mais nova):
    sudo pacman -S nvidia-open-dkms nvidia-utils linux-zen-headers
    nvidia-smi ......................... ver a placa e a temperatura
  AMD / Intel (ja vem pronto): mesa e vulkan ja estao instalados.
  Wi-Fi Broadcom:   sudo pacman -S broadcom-wl-dkms   (depois reinicie)
  Bluetooth:        sudo pacman -S bluez bluez-utils blueman
                    sudo systemctl enable --now bluetooth
                    blueman-applet &      (icone na bandeja)
  Firmware geral:   sudo pacman -S linux-firmware
  Temperaturas:     sudo pacman -S lm_sensors   e depois:  sensors
  Placa antiga (GTX 10xx ou mais velha): o driver open nao serve e o
  driver legado esta so no AUR (veja o item 7).

5) REDE
  nmtui ............................. menu de rede (texto)
  nmcli device wifi list ............ redes Wi-Fi ao alcance
  nmcli device wifi connect NOME password SENHA
  nmcli connection show ............. conexoes salvas
  ping -c 3 archlinux.org ........... testar a internet
  Icone de rede na barra de baixo tambem funciona.

6) JOGOS
  Opcoes de inicializacao do Steam (copie e cole):
    hkos-game %command% ........................... GameMode + perfil do jogo
    hkos-game --novsync --lowlat %command% ......... mais FPS e menos atraso
    hkos-game --fps 144 --reserve 2 %command% ...... FPS estavel e 2 nucleos livres
    hkos-game --sched bpfland --x3d %command% ...... agendador/V-Cache so no jogo
    hkos-game save APPID --novsync --lowlat ........ salva para aquele jogo
    hkos-bench -n antes -t 120 %command% ........... mede o FPS (depois: hkos-bench compare)
    Mais opcoes: hkos-game help
  GPU (hkos-gpu): limite de energia, clock maximo e overclock (NVIDIA:
    nucleo e memoria; AMD: energia e clock maximo). Comece com offset 25 no
    nucleo e 100 na memoria e teste um jogo antes de subir. NVIDIA nao tem
    controle de voltagem no Linux: "eficiente" limita energia e clock.
    "Aplicar ao ligar" so vale no HKOS instalado no disco.
  Steam: nas propriedades do jogo > Opcoes de inicializacao:
    mangohud %command% ................ mostra FPS e temperatura
    gamemoderun %command% ............. prioridade maxima (GameMode)
    gamescope -f -- %command% ......... tela cheia pelo Gamescope
    mangohud gamemoderun %command% .... os dois juntos
  Proton-GE: menu > Instalar Proton-GE, reinicie o Steam e escolha em
    Propriedades > Compatibilidade.
  Battle.net: menu > Battle.net (instala o Lutris e o Wine na 1a vez, ~1,5 GB;
    no pendrive use so com o HKOS instalado no disco). Depois procure no Lutris.
  Gamescope: nao vem instalado (mais leve). Instale em hkos-loja.
  Epic/GOG/Amazon: menu > Heroic (baixa na 1a vez, ~1 GB). Dentro dele,
    em Gerenciador de Wine, baixe o GE-Proton antes de instalar jogos.
  Ja vem ligado: mouse sem aceleracao, NTSYNC, threads OpenGL,
    cache de shaders de 10 GB, tela sem protetor, perfil maximo.
  Mais FPS: feche o navegador e o Discord durante o jogo, use
    "gamemoderun %command%" e deixe o jogo em tela cheia exclusiva.
  Se o jogo travar com Proton: troque a versao (Proton-GE) e tente.
  Por jogo (Opcoes de inicializacao do Steam), teste um de cada vez:
    LD_PRELOAD="" %command% ........ tira o overlay do Steam (acaba travadas)
    __GL_THREADED_OPTIMIZATIONS=1 %command% ... OpenGL em varias threads (NVIDIA)
    __GL_SYNC_TO_VBLANK=0 __GL_VRR_ALLOWED=0 %command% ... sem V-Sync (mais FPS, rasga)
    __GL_MaxFramesAllowed=1 %command% ... menos atraso de imagem
    mesa_glthread=true %command% ..... OpenGL em threads (AMD/Intel)
  No Steam > Configuracoes > Downloads: desmarque o pre-cache de shaders.
  Tambem ligado: mouse a 1000 Hz, GPU em desempenho pelo GameMode,
    disco com leitura/fila ajustadas, logs do Wine desligados.
  Jogos com anti-cheat de kernel (Valorant etc.) nao rodam no Linux.

7) PROGRAMAS DO AUR (nao vem instalado)
  O AUR tem programas que nao estao nos repositorios oficiais.
    sudo pacman -S --needed base-devel git
    git clone https://aur.archlinux.org/yay-bin.git
    cd yay-bin && makepkg -si
  Depois:  yay -S nome-do-programa
  Cuidado: pacotes do AUR sao de terceiros. Leia antes de instalar.

8) SISTEMA
  htop .............................. processos e uso de CPU/RAM
  free -h ........................... memoria
  lsblk ............................. discos e particoes
  df -h ............................. espaco em disco
  journalctl -b -p 3 ................ erros desde o boot
  systemctl --failed ................ servicos com falha
  systemctl reboot .................. reiniciar
  systemctl poweroff ................ desligar

9) SE ALGO DER ERRADO
  Steam, Firefox ou Discord nao abrem? No terminal rode um por vez:
    firefox 2>&1 | tail -20
    steam 2>&1 | tail -30
    discord 2>&1 | tail -20
  e depois:  journalctl -b -p 3 | tail -30
  Guarde o texto que aparecer.
  Rode hkos-info e guarde o texto (~/hkos-info.txt) para pedir ajuda.
HELP_EOF

put 755 usr/local/bin/hkos-ajuda <<'TOOL_EOF'
#!/usr/bin/env bash
# Mostra o guia de comandos do HKOS.
LESSCHARSET=utf-8 exec less -R /usr/share/hkos/ajuda.txt
TOOL_EOF

put 755 usr/local/bin/hkos-loja <<'TOOL_EOF'
#!/usr/bin/env bash
# hkos-loja - instala programas e drivers (pacman) com menus.
LIVE=0; [[ -d /run/archiso ]] && LIVE=1
SUDO=(); [[ $EUID -eq 0 ]] || SUDO=(sudo)

pm() { # instala pacotes (live: -Sy; instalado: -Syu para não deixar o sistema pela metade)
  if (( LIVE )); then "${SUDO[@]}" pacman -Sy --needed --noconfirm "$@"
  else "${SUDO[@]}" pacman -Syu --needed --noconfirm "$@"; fi
}
pause() { read -rp "Enter para voltar..." _; }

pkgs_for() { # nome-da-opção -> pacotes
  case "$1" in
    bluetooth)  echo "bluez bluez-utils blueman" ;;
    wifi_bcm)   echo "broadcom-wl-dkms" ;;
    sensors)    echo "lm_sensors" ;;
    nvtop)      echo "nvtop" ;;
    mpv)        echo "mpv" ;;
    vlc)        echo "vlc" ;;
    obs)        echo "obs-studio" ;;
    torrent)    echo "qbittorrent" ;;
    fetch)      echo "fastfetch" ;;
    archivers)  echo "p7zip unzip unrar" ;;
    gamescope)  echo "gamescope" ;;
    battlenet)  echo "lutris wine-staging winetricks wine-mono wine-gecko" ;;
  esac
}

valid_names() { [[ "$1" =~ ^[a-zA-Z0-9@._+\ -]+$ ]]; }

install_list() {
  local sel p list=() chosen
  sel="$(dialog --stdout --separate-output --title "Programas e drivers" \
    --checklist "Marque com Espaço e confirme com Enter:" 22 74 12 \
    bluetooth "Bluetooth (bluez + blueman)" off \
    wifi_bcm  "Wi-Fi Broadcom (broadcom-wl-dkms)" off \
    sensors   "Sensores de temperatura (lm_sensors)" off \
    nvtop     "Monitor da GPU (nvtop)" off \
    mpv       "Player de vídeo leve (mpv)" off \
    vlc       "VLC" off \
    obs       "OBS Studio (gravar e transmitir)" off \
    torrent   "qBittorrent" off \
    fetch     "fastfetch (info do sistema)" off \
    archivers "Zip, 7z e RAR (p7zip, unzip, unrar)" off \
    gamescope "Gamescope (modo console, tela cheia)" off \
    battlenet "Battle.net (Lutris + Wine, ~1,5 GB)" off)" || return 0
  [[ -n "$sel" ]] || return 0
  for chosen in $sel; do
    for p in $(pkgs_for "$chosen"); do list+=("$p"); done
  done
  clear
  echo "Instalando: ${list[*]}"
  if pm "${list[@]}"; then
    for chosen in $sel; do
      [[ "$chosen" == bluetooth ]] && "${SUDO[@]}" systemctl enable --now bluetooth.service
    done
    echo; echo "Pronto."
    [[ " $sel " == *" wifi_bcm "* ]] && echo "Reinicie para o driver de Wi-Fi funcionar."
    [[ " $sel " == *" bluetooth "* ]] && echo "Bluetooth: abra um terminal e rode  blueman-applet &"
  else
    echo; echo "Falhou. Sem internet, pacote inexistente ou pouco espaço (modo live)."
  fi
  pause
}

main() {
  command -v dialog >/dev/null || { echo "dialog ausente"; exit 1; }
  local C N Q note=""
  (( LIVE )) && note="Modo live: o que você instalar some ao reiniciar."
  while true; do
    C="$(dialog --stdout --title "HKOS Loja" --menu "$note" 18 66 8 \
      1 "Programas e drivers (lista pronta)" \
      2 "Instalar pelo nome" \
      3 "Pesquisar" \
      4 "Atualizar o sistema" \
      5 "Remover programa" \
      6 "Ajuda e comandos" \
      7 "Heroic Games Launcher (Epic/GOG)" \
      8 "Sair")" || exit 0
    case "$C" in
      1) install_list ;;
      2) N="$(dialog --stdout --inputbox "Nome do(s) pacote(s):" 8 62)" || continue
         valid_names "$N" || { dialog --msgbox "Nome inválido." 6 30; continue; }
         clear; pm $N || echo "Falhou."; pause ;;
      3) Q="$(dialog --stdout --inputbox "Pesquisar por:" 8 62)" || continue
         valid_names "$Q" || { dialog --msgbox "Texto inválido." 6 30; continue; }
         clear; { pacman -Ss "$Q" || echo "Nada encontrado (sem internet ou lista desatualizada: rode 'sudo pacman -Sy')."; } | less -R ;;
      4) clear
         if (( LIVE )); then echo "Atualizar no modo live baixa muita coisa para a memória. Prefira instalar no disco."
            read -rp "Continuar mesmo assim? [s/N] " r; [[ "$r" =~ ^[sS]$ ]] || continue; fi
         "${SUDO[@]}" pacman -Syu; pause ;;
      5) N="$(dialog --stdout --inputbox "Nome do pacote a remover:" 8 62)" || continue
         valid_names "$N" || { dialog --msgbox "Nome inválido." 6 30; continue; }
         clear; "${SUDO[@]}" pacman -Rns $N; pause ;;
      6) hkos-ajuda ;;
      7) hkos-heroic install ;;
      8) exit 0 ;;
    esac
  done
}
[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
TOOL_EOF

put 755 usr/local/bin/hkos-tweaks <<'TOOL_EOF'
#!/usr/bin/env bash
# Painel de ajustes do HKOS (terminal). Precisa de root.
[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"
command -v dialog >/dev/null || { echo "dialog não instalado"; exit 1; }
REAL_USER="${SUDO_USER:-root}"
EXTREME='pcie_aspm=off processor.max_cstate=1 intel_idle.max_cstate=1 threadirqs skew_tick=1'

# cmdline_param on|off "param1 param2 ..." (systemd-boot e GRUB)
cmdline_param() {
  local mode="$1" params="$2" f p esc
  for f in /boot/loader/entries/*.conf; do
    [[ -f "$f" ]] || continue
    for p in $params; do
      esc="$(printf '%s' "$p" | sed 's|[].[*^$/]|\\&|g')"
      sed -i "/^options/ s/ ${esc}\( \|\$\)/\1/g" "$f"
      [[ $mode == on ]] && sed -i "/^options/ s/\$/ $p/" "$f"
    done
  done
  if [[ -f /etc/default/grub ]]; then
    for p in $params; do
      esc="$(printf '%s' "$p" | sed 's|[].[*^$/]|\\&|g')"
      sed -i "/^GRUB_CMDLINE_LINUX_DEFAULT/ s/ ${esc}\( \|\"\)/\1/g" /etc/default/grub
      [[ $mode == on ]] && sed -i "/^GRUB_CMDLINE_LINUX_DEFAULT/ s/\"\$/ $p\"/" /etc/default/grub
    done
    grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
  fi
}

set_cpu() { # performance | balanced
  local gov epp c
  if [[ $1 == performance ]]; then gov=performance; epp=performance
  else
    gov=powersave
    grep -qw schedutil /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null && gov=schedutil
    epp=balance_performance
  fi
  for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
    echo "$gov" > "$c/scaling_governor" 2>/dev/null || true
    [[ -w "$c/energy_performance_preference" ]] && echo "$epp" > "$c/energy_performance_preference" 2>/dev/null
  done
  sed -i -e "s|\(scaling_governor - - - - \).*|\1$gov|" \
         -e "s|\(energy_performance_preference - - - - \).*|\1$epp|" /etc/tmpfiles.d/gameos-cpu.conf
}

set_power() { # max | balanced
  local p
  if [[ $1 == max ]]; then
    set_cpu performance
    cp /usr/share/gameos/power-max.conf /etc/tmpfiles.d/gameos-power.conf
    systemd-tmpfiles --create /etc/tmpfiles.d/gameos-power.conf 2>/dev/null || true
    cmdline_param on "$EXTREME"
  else
    set_cpu balanced
    rm -f /etc/tmpfiles.d/gameos-power.conf
    for p in /sys/bus/pci/devices/*/power/control; do echo auto > "$p" 2>/dev/null || true; done
    echo 0 > /sys/devices/system/cpu/intel_pstate/min_perf_pct 2>/dev/null || true
    for p in /sys/class/drm/card*/device/power_dpm_force_performance_level; do echo auto > "$p" 2>/dev/null || true; done
    cmdline_param off "$EXTREME"
  fi
}

set_scx() { # scx_lavd | scx_bpfland | off
  if [[ $1 == off ]]; then systemctl disable --now scx.service 2>/dev/null || true
  else
    if [[ $1 == scx_lavd ]]; then F="--performance"; else F="-m performance"; fi
    printf "SCX_SCHEDULER=%s\nSCX_FLAGS='%s'\n" "$1" "$F" > /etc/default/scx
    systemctl enable scx.service 2>/dev/null || true
    systemctl restart scx.service 2>/dev/null || true
  fi
}

while true; do
  C=$(dialog --stdout --title "Ajustes HKOS" --menu "Escolha:" 21 72 9 \
    1 "Perfil MÁXIMO (CPU, GPU, PCIe e USB sempre no limite) - padrão" \
    2 "Perfil equilibrado (gasta menos energia)" \
    3 "Agendador de jogos: LAVD (padrão)" \
    4 "Agendador de jogos: BPFLAND" \
    5 "Agendador de jogos: desligado" \
    6 "Mitigações de CPU: desligar (mais FPS, menos proteção) - padrão" \
    7 "Mitigações de CPU: ligar (mais seguro)" \
    8 "Modo console (Steam em tela cheia no próximo login)" \
    9 "Sair") || exit 0
  case "$C" in
    1) set_power max;      dialog --msgbox "Perfil máximo ativado. Parte vale só após reiniciar." 6 58 ;;
    2) set_power balanced; dialog --msgbox "Perfil equilibrado ativado. Parte vale só após reiniciar." 6 58 ;;
    3) set_scx scx_lavd ;;
    4) set_scx scx_bpfland ;;
    5) set_scx off ;;
    6) cmdline_param on mitigations=off;  dialog --msgbox "Desligadas. Vale a partir do próximo boot." 6 50 ;;
    7) cmdline_param off mitigations=off; dialog --msgbox "Ligadas. Vale a partir do próximo boot." 6 50 ;;
    8) sudo -u "$REAL_USER" env DISPLAY="${DISPLAY:-:0}" HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)" /usr/local/bin/hkos-mode console; exit 0 ;;
    9) exit 0 ;;
  esac
done
TOOL_EOF

put 755 usr/local/bin/hkos-install <<'INSTALLER_EOF'
#!/usr/bin/env bash
# HKOS - instalador automático (UEFI). Apaga o disco escolhido por inteiro.
# Dual boot e particionamento manual não são suportados por este instalador.
set -euo pipefail

# ---- funções (testáveis: HKOS_INSTALL_SOURCE=1 source hkos-install) ----
extra_pkgs() { # opção da lista -> pacotes
  case "$1" in
    bluetooth) echo "bluez bluez-utils blueman" ;;
    wifi_bcm)  echo "broadcom-wl-dkms" ;;
    sensors)   echo "lm_sensors" ;;
    nvtop)     echo "nvtop" ;;
    mpv)       echo "mpv" ;;
    vlc)       echo "vlc" ;;
    obs)       echo "obs-studio" ;;
    torrent)   echo "qbittorrent" ;;
    fetch)     echo "fastfetch" ;;
    archivers) echo "p7zip unzip unrar" ;;
    gamescope) echo "gamescope" ;;
    battlenet) echo "lutris wine-staging winetricks wine-mono wine-gecko" ;;
  esac
}
fw_detect() { # imprime os pacotes linux-firmware-* do hardware; falha se não der para reduzir com segurança
  command -v lspci >/dev/null 2>&1 || return 1
  local all pci f usbw=0 pk
  all="$(lspci -n 2>/dev/null)"
  # só reduz se a placa de vídeo for NVIDIA, AMD ou Intel; qualquer outra coisa: firmware completo
  awk '$2 ~ /^03[0-9a-f][0-9a-f]:$/ {print $3}' <<<"$all" | cut -d: -f1 | tr 'A-F' 'a-f' | grep -qxE '10de|1002|8086' || return 1
  pci="$(awk '{print $3}' <<<"$all" | cut -d: -f1 | tr 'A-F' 'a-f' | sort -u)"
  for f in /sys/bus/usb/devices/*/bInterfaceClass; do
    [[ -r "$f" && "$(cat "$f")" == e0 ]] && usbw=1            # Wi-Fi/Bluetooth USB: não dá para saber a marca
  done
  pk=(linux-firmware-whence linux-firmware-other linux-firmware-amd linux-firmware-cirrus linux-firmware-ti)
  grep -qx 10de <<<"$pci" && pk+=(linux-firmware-nvidia)
  grep -qx 1002 <<<"$pci" && pk+=(linux-firmware-amdgpu linux-firmware-radeon)
  grep -qx 8086 <<<"$pci" && pk+=(linux-firmware-intel)
  grep -qx 10ec <<<"$pci" && pk+=(linux-firmware-realtek)
  grep -qx 14c3 <<<"$pci" && pk+=(linux-firmware-mediatek)
  { grep -qx 168c <<<"$pci" || grep -qx 17cb <<<"$pci"; } && pk+=(linux-firmware-atheros)
  grep -qx 14e4 <<<"$pci" && pk+=(linux-firmware-broadcom)
  (( usbw )) && pk+=(linux-firmware-realtek linux-firmware-mediatek linux-firmware-atheros linux-firmware-broadcom linux-firmware-intel)
  printf '%s\n' "${pk[@]}" | sort -u
  return 0
}
fw_check() { # todos os pacotes existem no repositório?
  local p; for p in "$@"; do pacman -Si --config "$PC" "$p" >/dev/null 2>&1 || return 1; done
}
[[ "${HKOS_INSTALL_SOURCE:-0}" == 1 ]] && return 0
[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"
command -v dialog >/dev/null || { echo "dialog não encontrado."; exit 1; }
if [[ ! -d /sys/firmware/efi ]]; then
  echo "Este instalador precisa de boot UEFI. Reinicie em modo UEFI ." >&2
  exit 1
fi
if ! curl -fsS --max-time 8 https://archlinux.org >/dev/null 2>&1; then
  echo "Sem internet. Conecte (ícone de rede na barra) e rode de novo." >&2
  exit 1
fi

# --- 1) Pergunta o essencial ---
LIVE_DISK=""
if src="$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null)"; then
  LIVE_DISK="/dev/$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)"
fi
items=()
while read -r name size model; do
  [[ "$name" == "$LIVE_DISK" ]] && continue
  items+=("$name" "$size $model")
done < <(lsblk -dpno NAME,SIZE,MODEL -e7,11)
[[ ${#items[@]} -gt 0 ]] || { echo "Nenhum disco encontrado." >&2; exit 1; }

DISK="$(dialog --stdout --title "HKOS" --menu "Em qual disco instalar?\nTODO o conteúdo dele será apagado." 18 72 8 "${items[@]}")" || exit 0
dialog --title "ATENÇÃO" --defaultno --yesno "Apagar TUDO em $DISK e instalar o HKOS?\n\nIsso não tem volta. Dual boot não é suportado por este instalador." 10 64 || exit 0
HOSTN="$(dialog --stdout --inputbox "Nome do computador:" 8 50 hkos)" || exit 0
USERN="$(dialog --stdout --inputbox "Nome do usuário (minúsculas, sem espaço):" 8 50 gamer)" || exit 0
[[ "$USERN" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || { echo "Nome de usuário inválido." >&2; exit 1; }
PASS1="$(dialog --stdout --insecure --passwordbox "Senha do usuário $USERN:" 8 50)" || exit 0
PASS2="$(dialog --stdout --insecure --passwordbox "Repita a senha:" 8 50)" || exit 0
[[ -n "$PASS1" && "$PASS1" == "$PASS2" ]] || { echo "Senhas vazias ou diferentes." >&2; exit 1; }

FSTYPE="$(dialog --stdout --title "Sistema de arquivos" --menu "Onde ficam o sistema e os jogos:" 13 76 3 \
  ext4 "Padrão, o mais testado (recomendado)" \
  xfs  "Rápido com arquivos grandes (jogos)" \
  f2fs "Pensado para SSD/NVMe")" || exit 0
FWMODE="$(dialog --stdout --title "Firmware" --menu "Firmware são os arquivos que fazem a placa de vídeo, o Wi-Fi e a rede funcionarem:" 13 76 2 \
  detect "Só o do meu hardware (instalação menor)" \
  full   "Completo (mais seguro, ocupa mais espaço)")" || exit 0
SEL="$(dialog --stdout --separate-output --title "Programas extras (opcional)" \
  --checklist "Marque com Espaço o que quiser já instalado. Dá para instalar depois pelo hkos-loja." 22 76 12 \
  battlenet "Battle.net (Lutris + Wine, ~1,5 GB)" off \
  gamescope "Gamescope (modo console)" off \
  bluetooth "Bluetooth" off \
  obs       "OBS Studio (gravar e transmitir)" off \
  vlc       "VLC" off \
  mpv       "mpv (player leve)" off \
  torrent   "qBittorrent" off \
  nvtop     "nvtop (monitor da GPU)" off \
  sensors   "Sensores de temperatura" off \
  fetch     "fastfetch" off \
  archivers "Zip, 7z e RAR" off \
  wifi_bcm  "Wi-Fi Broadcom" off)" || SEL=""
ULTRA=0
dialog --title "Modo ultraleve" --defaultno --yesno "Iniciar direto no Steam em tela cheia, sem ícones, barra e notificações?\n(Dá para mudar depois: hkos-mode ultra / hkos-mode desktop)" 9 66 && ULTRA=1
clear

# --- 2) Particiona: ESP 1 GiB + raiz ext4 ---
P=""; [[ "$DISK" =~ [0-9]$ ]] && P="p"
EFI="${DISK}${P}1"; ROOT="${DISK}${P}2"
echo "==> Particionando $DISK"
umount -R /mnt 2>/dev/null || true
wipefs -af "$DISK" >/dev/null
sgdisk --zap-all "$DISK" >/dev/null
sgdisk -n1:0:+1GiB -t1:ef00 -c1:HKOS-ESP -n2:0:0 -t2:8300 -c2:HKOS-ROOT "$DISK" >/dev/null
partprobe "$DISK"; udevadm settle; sleep 2
mkfs.fat -F32 -n HKOS-ESP "$EFI" >/dev/null
FSPKG=()
case "$FSTYPE" in
  xfs)  mkfs.xfs -f -q -L HKOS "$ROOT"; FSPKG=(xfsprogs) ;;
  f2fs) mkfs.f2fs -f -l HKOS "$ROOT" >/dev/null; FSPKG=(f2fs-tools) ;;
  *)    mkfs.ext4 -F -q -L HKOS "$ROOT" ;;
esac
mount "$ROOT" /mnt
mkdir -p /mnt/boot
mount "$EFI" /mnt/boot

# --- 3) Instala o sistema ---
echo "==> Instalando pacotes (vários minutos, precisa de internet)"
PC="$(mktemp)"; cp /etc/pacman.conf "$PC"
sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' "$PC"
if [[ -f /usr/share/gameos/repo/hkos.db ]]; then
  printf '\n[hkos]\nSigLevel = Optional TrustAll\nServer = file:///usr/share/gameos/repo\n' >> "$PC"
fi
sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 10/' "$PC"
mapfile -t PKGS < <(grep -vE '^\s*(#|$)' /usr/share/gameos/packages.txt | grep -vx 'archinstall')

# microcode só do fabricante da CPU
case "$(grep -m1 -o 'GenuineIntel\|AuthenticAMD' /proc/cpuinfo || true)" in
  GenuineIntel) mapfile -t PKGS < <(printf '%s\n' "${PKGS[@]}" | grep -vx 'amd-ucode' || true) ;;
  AuthenticAMD) mapfile -t PKGS < <(printf '%s\n' "${PKGS[@]}" | grep -vx 'intel-ucode' || true) ;;
esac
# firmware: só o do hardware detectado (ou completo se não der para reduzir com segurança)
if [[ "$FWMODE" == detect ]]; then
  pacman -Sy --noconfirm --config "$PC" >/dev/null 2>&1 || true
  mapfile -t FW < <(fw_detect || true)
  if (( ${#FW[@]} > 0 )) && fw_check "${FW[@]}"; then
    echo "==> Firmware só do seu hardware: ${FW[*]}"
    mapfile -t PKGS < <(printf '%s\n' "${PKGS[@]}" | grep -vx 'linux-firmware' || true)
    PKGS+=("${FW[@]}")
  else
    echo "==> Firmware completo (não consegui reduzir com segurança)"
  fi
fi
# programas extras escolhidos
EXTRA=(); SERV=""
for o in $SEL; do
  for p in $(extra_pkgs "$o"); do EXTRA+=("$p"); done
  if [[ "$o" == bluetooth ]]; then SERV="bluetooth"; fi
done
pacstrap -C "$PC" -K /mnt base mkinitcpio lz4 dialog earlyoom pciutils "${PKGS[@]}" "${FSPKG[@]}" "${EXTRA[@]}"

echo "==> Aplicando ajustes do HKOS"
while read -r f; do
  [[ -n "$f" ]] && install -D -m 0644 "/$f" "/mnt/$f"
done < /usr/share/gameos/files.txt
for s in hkos-mode hkos-proton-ge hkos-heroic hkos-explorer hkos-run hkos-battlenet hkos-gpu hkos-gpu-root hkos-game hkos-game-root hkos-bench hkos-info hkos-tweaks hkos-fan hkos-ajuda hkos-loja; do
  install -D -m 0755 "/usr/local/bin/$s" "/mnt/usr/local/bin/$s"
done
install -d /mnt/usr/share/hkos
cp -a /usr/share/hkos/skel /mnt/usr/share/hkos/
sed -i '/hkos-install/d' /mnt/usr/share/hkos/skel/.config/openbox/menu.xml
genfstab -U /mnt >> /mnt/etc/fstab
sed -i 's/\brelatime\b/noatime/g' /mnt/etc/fstab
echo 'tmpfs /tmp tmpfs defaults,noatime,mode=1777,size=50% 0 0' >> /mnt/etc/fstab

# --- 4) Configura dentro do sistema novo ---
CMD='quiet loglevel=3 mitigations=off nowatchdog split_lock_detect=off audit=0 nvme_core.default_ps_max_latency_us=0 usbcore.autosuspend=-1 amdgpu.ppfeaturemask=0xffffffff pcie_aspm=off processor.max_cstate=1 intel_idle.max_cstate=1 threadirqs skew_tick=1 iommu=pt workqueue.power_efficient=0 cpufreq.default_governor=performance amd_pstate=active usbhid.mousepoll=1 i915.enable_psr=0'
ROOT_UUID="$(blkid -s UUID -o value "$ROOT")"
cat > /mnt/root/hkos-setup.sh <<'SETUP_EOF'
#!/usr/bin/env bash
set -euo pipefail
HOSTN="$1"; USERN="$2"; EXTRAS="${3:-}"; ULTRA="${4:-0}"
ln -sf /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime
hwclock --systohc || true
sed -i -e 's/^#\(en_US.UTF-8\)/\1/' -e 's/^#\(pt_BR.UTF-8\)/\1/' /etc/locale.gen
locale-gen
echo 'LANG=pt_BR.UTF-8' > /etc/locale.conf
echo "$HOSTN" > /etc/hostname
GROUPS_LIST="wheel,video,audio,input"
getent group gamemode >/dev/null && GROUPS_LIST="$GROUPS_LIST,gamemode"
useradd -m -G "$GROUPS_LIST" -s /bin/bash "$USERN"
cp -rf /usr/share/hkos/skel/. "/home/$USERN/"
chown -R "$USERN:$USERN" "/home/$USERN"
if [[ "$ULTRA" == 1 ]]; then
  install -d -o "$USERN" -g "$USERN" "/home/$USERN/.config"
  touch "/home/$USERN/.config/hkos-ultra"; chown "$USERN:$USERN" "/home/$USERN/.config/hkos-ultra"
fi
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
echo '%wheel ALL=(root) NOPASSWD: /usr/local/bin/hkos-gpu-root, /usr/local/bin/hkos-game-root' > /etc/sudoers.d/20-hkos-gpu
chmod 440 /etc/sudoers.d/20-hkos-gpu
passwd -l root >/dev/null
install -d /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<'AUTOLOGIN'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --autologin HKOS_USER %I $TERM
AUTOLOGIN
sed -i "s/HKOS_USER/$USERN/" /etc/systemd/system/getty@tty1.service.d/autologin.conf
# initramfs enxuto e rápido: só o necessário, compressão lz4, sem imagem de fallback
install -d /etc/mkinitcpio.conf.d
cat > /etc/mkinitcpio.conf.d/hkos.conf <<'MKCONF'
HOOKS=(base udev autodetect modconf block filesystems fsck)
COMPRESSION="lz4"
MKCONF
if [[ -f /etc/mkinitcpio.d/linux-zen.preset ]]; then
  sed -i "s/^PRESETS=.*/PRESETS=('default')/" /etc/mkinitcpio.d/linux-zen.preset
fi
mkinitcpio -P
rm -f /boot/initramfs-linux-zen-fallback.img
systemctl enable NetworkManager.service fstrim.timer earlyoom.service systemd-timesyncd.service
systemctl enable scx.service || true
systemctl enable nvidia-persistenced.service || true
systemctl enable systemd-boot-update.service || true
systemctl disable NetworkManager-wait-online.service || true
if [[ "$EXTRAS" == *bluetooth* ]]; then systemctl enable bluetooth.service || true; fi
systemctl mask man-db.timer shadow.timer archlinux-keyring-wkd-sync.timer || true
SETUP_EOF
chmod 755 /mnt/root/hkos-setup.sh
echo "$USERN:$PASS1" > /mnt/root/.hkos-pw
arch-chroot /mnt /root/hkos-setup.sh "$HOSTN" "$USERN" "$SERV" "$ULTRA"
arch-chroot /mnt bash -c 'chpasswd < /root/.hkos-pw'
shred -u /mnt/root/.hkos-pw; rm -f /mnt/root/hkos-setup.sh

# --- 5) Bootloader (systemd-boot) ---
echo "==> Instalando o bootloader"
bootctl --esp-path=/mnt/boot install
cat > /mnt/boot/loader/loader.conf <<'EOF'
default hkos.conf
timeout 0
console-mode max
editor no
EOF
{
  echo "title   HKOS"
  echo "linux   /vmlinuz-linux-zen"
  [[ -f /mnt/boot/amd-ucode.img ]]   && echo "initrd  /amd-ucode.img"
  [[ -f /mnt/boot/intel-ucode.img ]] && echo "initrd  /intel-ucode.img"
  echo "initrd  /initramfs-linux-zen.img"
  echo "options root=UUID=$ROOT_UUID rw $CMD"
} > /mnt/boot/loader/entries/hkos.conf

sync
umount -R /mnt
cat <<'EOF'

Instalação concluída! Remova o pendrive e reinicie.
O sistema entra direto no desktop. Botão direito na área de trabalho abre o menu.
Para o Battle.net: menu > Battle.net. Para o Proton-GE: menu > Instalar Proton-GE.

EOF
INSTALLER_EOF

if [[ "$KERNEL" != linux-zen ]]; then
  sed -i "s/linux-zen/$KERNEL/g" "$AIROOT/usr/local/bin/hkos-install" "$AIROOT/usr/share/hkos/ajuda.txt"
fi

[[ "${DRYRUN:-0}" == 1 ]] && { echo "dry-run ok: $PROFILE"; exit 0; }

###############################################################################
# 8) GERA A ISO
###############################################################################
mkarchiso -v -w "$WORK/work" -o "$OUT" "$PROFILE"
echo "ISO gerada em: $OUT"
ls -lh "$OUT"
