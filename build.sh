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
cp -rT "$HERE/airootfs" "$AIROOT"

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
# 2) KERNEL ZEN: preset do initramfs, entradas de boot, nome e parâmetros
###############################################################################
rm -f "$AIROOT/etc/mkinitcpio.d/linux.preset"
put 644 etc/mkinitcpio.d/linux-zen.preset <<'EOF'
# mkinitcpio preset do HKOS (kernel linux-zen)
PRESETS=('archiso')

ALL_kver='/boot/vmlinuz-linux-zen'
archiso_config='/etc/mkinitcpio.conf.d/archiso.conf'

archiso_image="/boot/initramfs-linux-zen.img"
EOF

LIVE_CMD='mitigations=off nowatchdog split_lock_detect=off audit=0 nvme_core.default_ps_max_latency_us=0 usbcore.autosuspend=-1'
for d in grub syslinux efiboot; do
  [[ -d "$PROFILE/$d" ]] || continue
  find "$PROFILE/$d" -type f -exec sed -i \
    -e 's|vmlinuz-linux|vmlinuz-linux-zen|g' \
    -e 's|initramfs-linux\.img|initramfs-linux-zen.img|g' \
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
  -e "/^file_permissions=(/a\\  [\"/$SK/.xinitrc\"]=\"0:0:755\"" \
  "$PROFILE/profiledef.sh"

for s in hkos-mode hkos-info hkos-tweaks hkos-proton-ge; do
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
xset s off -dpms
OB="$HOME/.config/openbox"
if [ ! -f "$OB/rc.xml" ]; then
  mkdir -p "$OB"
  cp /etc/xdg/openbox/rc.xml "$OB/rc.xml"
  sed -i -e 's|<name>Clearlooks</name>|<name>Onyx</name>|' \
         -e 's|<animateIconify>yes|<animateIconify>no|' "$OB/rc.xml"
fi
exec openbox-session
EOF
put 644 $SK/.Xresources <<'EOF'
Xft.dpi: 96
xterm*faceName: DejaVu Sans Mono
xterm*faceSize: 11
xterm*background: #0d0d0d
xterm*foreground: #e6e6e6
xterm*cursorColor: #e6e6e6
xterm*scrollBar: false
xterm*saveLines: 5000
xterm*selectToClipboard: true
EOF
put 755 $SK/.config/openbox/autostart <<'EOF'
xsetroot -cursor_name left_ptr &
if [ -f /usr/share/wallpapers/HKOS/hkos.png ]; then
  feh --no-fehbg --bg-fill /usr/share/wallpapers/HKOS/hkos.png &
else
  xsetroot -solid '#000000' &
fi
tint2 &
nm-applet &
volumeicon &
EOF
put 644 $SK/.config/openbox/menu.xml <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
<menu id="root-menu" label="HKOS">
  <item label="Steam"><action name="Execute"><command>steam</command></action></item>
  <item label="Discord"><action name="Execute"><command>discord</command></action></item>
  <item label="Firefox"><action name="Execute"><command>firefox</command></action></item>
  <item label="Lutris (Battle.net)"><action name="Execute"><command>lutris</command></action></item>
  <separator/>
  <item label="Terminal"><action name="Execute"><command>xterm</command></action></item>
  <item label="Volume"><action name="Execute"><command>pavucontrol</command></action></item>
  <separator/>
  <item label="Modo console (Steam em tela cheia)"><action name="Execute"><command>hkos-mode console</command></action></item>
  <item label="Ajustes HKOS"><action name="Execute"><command>xterm -e sudo hkos-tweaks</command></action></item>
  <item label="Instalar Proton-GE"><action name="Execute"><command>xterm -e hkos-proton-ge</command></action></item>
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
background_color = #0d0d0d 100
border_color = #000000 0
background_color_hover = #0d0d0d 100
border_color_hover = #000000 0
background_color_pressed = #0d0d0d 100
border_color_pressed = #000000 0

rounded = 3
border_width = 0
background_color = #262626 100
border_color = #000000 0
background_color_hover = #343434 100
border_color_hover = #000000 0
background_color_pressed = #343434 100
border_color_pressed = #000000 0

rounded = 3
border_width = 1
background_color = #3a3a3a 100
border_color = #e6e6e6 60
background_color_hover = #484848 100
border_color_hover = #e6e6e6 60
background_color_pressed = #484848 100
border_color_pressed = #e6e6e6 60

panel_items = LTSC
panel_size = 100% 36
panel_margin = 0 0
panel_padding = 4 3 4
panel_background_id = 1
panel_position = bottom center horizontal
panel_layer = top
panel_monitor = all
strut_policy = follow_size
autohide = 0

launcher_padding = 4 2 6
launcher_background_id = 0
launcher_icon_size = 26
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
      "media.ffmpeg.vaapi.enabled": { "Value": true, "Status": "default" }
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
EOF
put 644 etc/default/scx <<'EOF'
# Agendador sched_ext (como CachyOS/Bazzite): LAVD, feito para jogos e baixa latência
SCX_SCHEDULER=scx_lavd
EOF
put 644 etc/NetworkManager/conf.d/20-hkos.conf <<'EOF'
[connection]
wifi.powersave=2
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
EOF
put 644 etc/environment <<'EOF'
__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1
MESA_SHADER_CACHE_MAX_SIZE=10G
EOF
put 644 etc/sysctl.d/99-gameos.conf <<'EOF'
# HKOS - memória, agendador e rede para jogos
vm.swappiness = 100
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
EOF

# Arquivos que o instalador copia para o sistema instalado
SHIPPED=(
  etc/sysctl.d/99-gameos.conf
  etc/udev/rules.d/60-ioschedulers.rules
  etc/systemd/zram-generator.conf.d/gameos.conf
  etc/security/limits.d/10-gameos.conf
  etc/modprobe.d/gameos.conf
  etc/modules-load.d/gameos.conf
  etc/systemd/journald.conf.d/gameos.conf
  etc/systemd/coredump.conf.d/gameos.conf
  etc/systemd/system.conf.d/gameos.conf
  etc/tmpfiles.d/gameos-cpu.conf
  etc/default/scx
  etc/NetworkManager/conf.d/20-hkos.conf
  etc/gamemode.ini
  etc/environment
  etc/gtk-3.0/settings.ini etc/gtk-4.0/settings.ini
  etc/firefox/policies/policies.json
  etc/vconsole.conf
  etc/X11/xorg.conf.d/00-keyboard.conf
  etc/os-release etc/motd
)
[[ "$HAS_WALL" == 1 ]] && SHIPPED+=("$WALL")
mkdir -p "$AIROOT/usr/share/gameos"
printf '%s\n' "${SHIPPED[@]}" > "$AIROOT/usr/share/gameos/files.txt"
cp "$HERE/packages.extra" "$AIROOT/usr/share/gameos/packages.txt"

###############################################################################
# 7) FERRAMENTAS HKOS: instalador, modo console, ajustes, Proton-GE, diagnóstico
###############################################################################
put 755 usr/local/bin/hkos-mode <<'TOOL_EOF'
#!/usr/bin/env bash
# hkos-mode console | console-always | desktop
# console: abre o Steam em tela cheia (Gamescope, sem desktop) no próximo login.
F="$HOME/.config/hkos-console"
mkdir -p "$(dirname "$F")"
case "${1:-}" in
  console)        echo once > "$F" ;;
  console-always) echo always > "$F" ;;
  desktop)        rm -f "$F"; echo "Modo desktop ativado."; exit 0 ;;
  *) echo "uso: hkos-mode console | console-always | desktop"; exit 1 ;;
esac
echo "Modo console ativado. Saindo do desktop..."
[[ -n "${DISPLAY:-}" ]] && openbox --exit
TOOL_EOF

put 755 usr/local/bin/hkos-proton-ge <<'TOOL_EOF'
#!/usr/bin/env bash
# Baixa o Proton-GE mais recente para o Steam (precisa de internet).
set -euo pipefail
DEST="$HOME/.local/share/Steam/compatibilitytools.d"
mkdir -p "$DEST"
echo "Buscando a versão mais recente do Proton-GE..."
URL="$(curl -fsSL https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest \
  | grep -o '"browser_download_url": *"[^"]*\.tar\.gz"' | head -1 | cut -d'"' -f4 || true)"
if [[ -z "$URL" ]]; then
  echo "Não consegui achar o download (sem internet?)."; read -rp "Enter para fechar..." _; exit 1
fi
echo "Baixando: $URL"
curl -fL --progress-bar "$URL" | tar -xz -C "$DEST"
echo
echo "Pronto. Reinicie o Steam; nas propriedades do jogo, em Compatibilidade, escolha o Proton-GE."
read -rp "Enter para fechar..." _
TOOL_EOF

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
echo "-- Serviços com falha"; systemctl --failed --no-legend
echo "-- Erros do boot"; journalctl -b -p 3 --no-pager 2>/dev/null | tail -40
echo "-- startx.log"; tail -20 "$HOME/.startx.log" 2>/dev/null
echo "-- Xorg (EE)"; grep -h '(EE)' "$HOME"/.local/share/xorg/Xorg.*.log 2>/dev/null | tail -20
} 2>&1 | tee "$OUT"
echo; echo "Salvo em $OUT"
read -rp "Enter para fechar..." _
TOOL_EOF

put 755 usr/local/bin/hkos-tweaks <<'TOOL_EOF'
#!/usr/bin/env bash
# Painel de ajustes do HKOS (terminal). Precisa de root.
[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"
command -v dialog >/dev/null || { echo "dialog não instalado"; exit 1; }
REAL_USER="${SUDO_USER:-root}"

set_cpu() { # performance | balanced
  local gov epp
  if [[ $1 == performance ]]; then gov=performance; epp=performance
  else
    gov=powersave
    grep -qw schedutil /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null && gov=schedutil
    epp=balance_performance
  fi
  for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
    echo "$gov" > "$c/scaling_governor" 2>/dev/null || true
    [[ -w "$c/energy_performance_preference" ]] && echo "$epp" > "$c/energy_performance_preference" 2>/dev/null || true
  done
  sed -i -e "s|\(scaling_governor - - - - \).*|\1$gov|" \
         -e "s|\(energy_performance_preference - - - - \).*|\1$epp|" /etc/tmpfiles.d/gameos-cpu.conf
}

set_scx() { # scx_lavd | scx_bpfland | off
  if [[ $1 == off ]]; then systemctl disable --now scx.service 2>/dev/null || true
  else
    echo "SCX_SCHEDULER=$1" > /etc/default/scx
    systemctl enable scx.service 2>/dev/null || true
    systemctl restart scx.service 2>/dev/null || true
  fi
}

set_mitigations() { # on | off
  local f
  for f in /boot/loader/entries/*.conf; do
    [[ -f "$f" ]] || continue
    if [[ $1 == off ]]; then grep -q 'mitigations=off' "$f" || sed -i '/^options/ s/$/ mitigations=off/' "$f"
    else sed -i '/^options/ s/ mitigations=off//' "$f"; fi
  done
  if [[ -f /etc/default/grub ]]; then
    if [[ $1 == off ]]; then grep -q 'mitigations=off' /etc/default/grub || sed -i 's/^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 mitigations=off"/' /etc/default/grub
    else sed -i 's/ mitigations=off//' /etc/default/grub; fi
    grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
  fi
}

while true; do
  C=$(dialog --stdout --title "Ajustes HKOS" --menu "Escolha:" 20 68 9 \
    1 "CPU: máximo desempenho (padrão)" \
    2 "CPU: equilibrado (gasta menos energia)" \
    3 "Agendador de jogos: LAVD (padrão)" \
    4 "Agendador de jogos: BPFLAND" \
    5 "Agendador de jogos: desligado" \
    6 "Mitigações de CPU: desligar (mais FPS, menos proteção)" \
    7 "Mitigações de CPU: ligar (mais seguro)" \
    8 "Modo console (Steam em tela cheia no próximo login)" \
    9 "Sair") || exit 0
  case "$C" in
    1) set_cpu performance ;;
    2) set_cpu balanced ;;
    3) set_scx scx_lavd ;;
    4) set_scx scx_bpfland ;;
    5) set_scx off ;;
    6) set_mitigations off; dialog --msgbox "Desligadas. Vale a partir do próximo boot." 6 50 ;;
    7) set_mitigations on;  dialog --msgbox "Ligadas. Vale a partir do próximo boot." 6 50 ;;
    8) sudo -u "$REAL_USER" env DISPLAY="${DISPLAY:-:0}" HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)" /usr/local/bin/hkos-mode console; exit 0 ;;
    9) exit 0 ;;
  esac
done
TOOL_EOF

put 755 usr/local/bin/hkos-install <<'INSTALLER_EOF'
#!/usr/bin/env bash
# HKOS - instalador automático (UEFI). Apaga o disco escolhido por inteiro.
# Para dual boot ou particionamento manual, use o comando "archinstall".
set -euo pipefail
[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"
command -v dialog >/dev/null || { echo "dialog não encontrado."; exit 1; }
if [[ ! -d /sys/firmware/efi ]]; then
  echo "Este instalador precisa de boot UEFI. Reinicie em modo UEFI (ou use o archinstall)." >&2
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
mkfs.ext4 -F -q -L HKOS "$ROOT"
mount "$ROOT" /mnt
mkdir -p /mnt/boot
mount "$EFI" /mnt/boot

# --- 3) Instala o sistema ---
echo "==> Instalando pacotes (vários minutos, precisa de internet)"
PC="$(mktemp)"; cp /etc/pacman.conf "$PC"
sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' "$PC"
sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 10/' "$PC"
mapfile -t PKGS < <(grep -vE '^\s*(#|$)' /usr/share/gameos/packages.txt | grep -vx 'archinstall')
pacstrap -C "$PC" -K /mnt base mkinitcpio dialog earlyoom pciutils "${PKGS[@]}"

echo "==> Aplicando ajustes do HKOS"
while read -r f; do
  [[ -n "$f" ]] && install -D -m 0644 "/$f" "/mnt/$f"
done < /usr/share/gameos/files.txt
for s in hkos-mode hkos-proton-ge hkos-info hkos-tweaks; do
  install -D -m 0755 "/usr/local/bin/$s" "/mnt/usr/local/bin/$s"
done
install -d /mnt/usr/share/hkos
cp -a /usr/share/hkos/skel /mnt/usr/share/hkos/
sed -i '/hkos-install/d' /mnt/usr/share/hkos/skel/.config/openbox/menu.xml
genfstab -U /mnt >> /mnt/etc/fstab
sed -i 's/\brelatime\b/noatime/g' /mnt/etc/fstab

# --- 4) Configura dentro do sistema novo ---
CMD='quiet loglevel=3 mitigations=off nowatchdog split_lock_detect=off audit=0 nvme_core.default_ps_max_latency_us=0 usbcore.autosuspend=-1'
ROOT_UUID="$(blkid -s UUID -o value "$ROOT")"
cat > /mnt/root/hkos-setup.sh <<'SETUP_EOF'
#!/usr/bin/env bash
set -euo pipefail
HOSTN="$1"; USERN="$2"
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
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
passwd -l root >/dev/null
install -d /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<'AUTOLOGIN'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --autologin HKOS_USER %I $TERM
AUTOLOGIN
sed -i "s/HKOS_USER/$USERN/" /etc/systemd/system/getty@tty1.service.d/autologin.conf
mkinitcpio -P
systemctl enable NetworkManager.service fstrim.timer earlyoom.service systemd-timesyncd.service
systemctl enable scx.service || true
systemctl enable systemd-boot-update.service || true
systemctl disable NetworkManager-wait-online.service || true
SETUP_EOF
chmod 755 /mnt/root/hkos-setup.sh
echo "$USERN:$PASS1" > /mnt/root/.hkos-pw
arch-chroot /mnt /root/hkos-setup.sh "$HOSTN" "$USERN"
arch-chroot /mnt bash -c 'chpasswd < /root/.hkos-pw'
shred -u /mnt/root/.hkos-pw; rm -f /mnt/root/hkos-setup.sh

# --- 5) Bootloader (systemd-boot) ---
echo "==> Instalando o bootloader"
bootctl --esp-path=/mnt/boot install
cat > /mnt/boot/loader/loader.conf <<'EOF'
default hkos.conf
timeout 1
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
Para o Battle.net: abra o Lutris. Para o Proton-GE: menu > Instalar Proton-GE.

EOF
INSTALLER_EOF

[[ "${DRYRUN:-0}" == 1 ]] && { echo "dry-run ok: $PROFILE"; exit 0; }

###############################################################################
# 8) GERA A ISO
###############################################################################
mkarchiso -v -w "$WORK/work" -o "$OUT" "$PROFILE"
echo "ISO gerada em: $OUT"
ls -lh "$OUT"
