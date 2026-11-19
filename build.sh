#!/usr/bin/env bash
# HKOS - monta o perfil archiso (baseado no releng) e gera a ISO.
# Precisa rodar como root dentro de um Arch Linux (ou de um container archlinux).
# Quase todas as configurações são escritas aqui mesmo (função put), então
# atualizar o projeto = trocar só este arquivo e o packages.extra.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-/tmp/gameos-work}"
OUT="${OUT:-$HERE/out}"
RELENG="${RELENG:-/usr/share/archiso/configs/releng}"
PROFILE="$WORK/profile"
AIROOT="$PROFILE/airootfs"

[[ $EUID -eq 0 ]] || { echo "Rode como root." >&2; exit 1; }
[[ "${DRYRUN:-0}" == 1 ]] || command -v mkarchiso >/dev/null || pacman -Sy --noconfirm archiso

# put <modo> <caminho-no-airootfs>  (conteúdo vem do stdin)
put() { mkdir -p "$(dirname "$AIROOT/$2")"; rm -f "$AIROOT/$2"; cat > "$AIROOT/$2"; chmod "$1" "$AIROOT/$2"; }

rm -rf "$WORK"
mkdir -p "$PROFILE" "$OUT"
cp -r "$RELENG"/. "$PROFILE/"
cp -rT "$HERE/airootfs" "$AIROOT"

###############################################################################
# 1) PACOTES: tira o que não serve (debloat) e põe os do HKOS
###############################################################################
PKGLIST="$PROFILE/packages.x86_64"
REMOVE=(
  linux broadcom-wl b43-fwcutter                       # kernel padrão (trocado pelo zen)
  brltty espeakup livecd-sounds                        # acessibilidade/voz da ISO
  clonezilla partclone partimage fsarchiver testdisk ddrescue
  darkhttpd irssi lftp nmap tcpdump gpm mc screen tmux
  openvpn openconnect vpnc ppp pptpclient rp-pppoe wvdial xl2tpd
  modemmanager usb_modeswitch nfs-utils nbd open-iscsi udftools usbmuxd
  hyperv qemu-guest-agent virtualbox-guest-utils-nox open-vm-tools
  reiserfsprogs jfsutils nilfs-utils cloud-init ndisc6
  man-db man-pages vim                                 # documentação e editor pesado
)
for p in "${REMOVE[@]}"; do sed -i "/^${p}\$/d" "$PKGLIST"; done
grep -vE '^\s*(#|$)' "$HERE/packages.extra" >> "$PKGLIST"

cat >> "$PROFILE/pacman.conf" <<'EOF'

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF
# Downloads paralelos (build e instalação mais rápidos)
sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 10/' "$PROFILE/pacman.conf"
grep -q '^ParallelDownloads' "$PROFILE/pacman.conf" || sed -i '/^\[options\]/a ParallelDownloads = 10' "$PROFILE/pacman.conf"

###############################################################################
# 2) KERNEL ZEN: preset do initramfs e entradas de boot
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
# 3) IDENTIDADE E PERMISSÕES
###############################################################################
sed -i \
  -e 's|^iso_name=.*|iso_name="hkos"|' \
  -e 's|^iso_label=.*|iso_label="HKOS_$(date +%Y%m)"|' \
  -e 's|^iso_application=.*|iso_application="HKOS Live/Install ISO"|' \
  -e "s|^airootfs_image_tool_options=.*|airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '15' '-b' '1M')|" \
  -e '/^file_permissions=(/a\  ["/usr/local/bin/hkos-install"]="0:0:755"' \
  -e '/^file_permissions=(/a\  ["/usr/local/bin/gameos-firstboot"]="0:0:755"' \
  -e '/^file_permissions=(/a\  ["/etc/sudoers.d/10-gameos"]="0:0:440"' \
  "$PROFILE/profiledef.sh"

# Usuário da sessão live (sem senha, entra direto no desktop)
grep -q '^gamer:' "$AIROOT/etc/passwd"  || echo 'gamer:x:1000:1000:HKOS Live:/home/gamer:/bin/bash' >> "$AIROOT/etc/passwd"
grep -q '^gamer:' "$AIROOT/etc/shadow"  || echo 'gamer::14871::::::' >> "$AIROOT/etc/shadow"
grep -q '^gamer:' "$AIROOT/etc/group"   || echo 'gamer:x:1000:' >> "$AIROOT/etc/group"
grep -q '^gamer:' "$AIROOT/etc/gshadow" || echo 'gamer:!::' >> "$AIROOT/etc/gshadow"

# Nome, identidade e mensagem de boas-vindas do HKOS
rm -f "$AIROOT/usr/local/bin/gameos-install"
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

  HKOS - HK Tech | sistema Linux otimizado para jogos (base Arch Linux)

  Instalar no disco:   sudo hkos-install
  Steam, Lutris (Battle.net), Discord e Firefox já estão no menu.

EOF

# A pasta do usuário live é criada no boot (só no live; não vai para o instalado)
put 644 etc/tmpfiles.d/gameos-live.conf <<'EOF'
d /home/gamer 0700 gamer gamer -
EOF

###############################################################################
# 4) SERVIÇOS: remove o que o live não precisa (ssh, voz, VMs, reflector...)
###############################################################################
find "$AIROOT/etc/systemd/system" \( \
  -name 'livecd-*' -o -name 'espeakup*' -o -name 'brltty*' -o -name 'hv_*' \
  -o -name 'vboxservice*' -o -name 'vmtoolsd*' -o -name 'vmware-*' \
  -o -name 'qemu-guest-agent*' -o -name 'systemd-networkd*' -o -name 'iwd.service' \
  -o -name 'ModemManager*' -o -name 'sshd*' -o -name 'reflector*' \) \
  -exec rm -rf {} + 2>/dev/null || true

enable() { mkdir -p "$AIROOT/etc/systemd/system/$2.wants"; ln -sf "/usr/lib/systemd/system/$1" "$AIROOT/etc/systemd/system/$2.wants/$1"; }
enable NetworkManager.service multi-user.target
enable bluetooth.service bluetooth.target
ln -sf /usr/lib/systemd/system/sddm.service "$AIROOT/etc/systemd/system/display-manager.service"

###############################################################################
# 5) SEM ANIMAÇÕES, SEM EFEITOS, SEM INDEXAÇÃO (KDE + GTK + Firefox)
###############################################################################
put 644 etc/xdg/kdeglobals <<'EOF'
[General]
ColorScheme=BreezeDark

[Icons]
Theme=breeze-dark

[KDE]
AnimationDurationFactor=0
LookAndFeelPackage=org.kde.breezedark.desktop
EOF
put 644 etc/xdg/kwinrc <<'EOF'
[Plugins]
blurEnabled=false
contrastEnabled=false
dimscreenEnabled=false
fadeEnabled=false
fadedesktopEnabled=false
fadingpopupsEnabled=false
frozenappEnabled=false
glideEnabled=false
loginEnabled=false
logoutEnabled=false
maximizeEnabled=false
morphingpopupsEnabled=false
scaleEnabled=false
sheetEnabled=false
slideEnabled=false
slidingpopupsEnabled=false
squashEnabled=false
windowapertureEnabled=false
wobblywindowsEnabled=false
EOF
put 644 etc/xdg/baloofilerc <<'EOF'
[Basic Settings]
Indexing-Enabled=false
EOF
put 644 etc/xdg/ksplashrc <<'EOF'
[KSplash]
Engine=none
Theme=None
EOF
put 644 etc/xdg/kwalletrc <<'EOF'
[Wallet]
Enabled=false
EOF
put 644 etc/xdg/kscreenlockerrc <<'EOF'
[Daemon]
Autolock=false
LockOnResume=false
EOF
for v in 3 4; do
  put 644 "etc/gtk-$v.0/settings.ini" <<'EOF'
[Settings]
gtk-enable-animations=false
gtk-application-prefer-dark-theme=true
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

# Papel de parede HK Tech (wallpaper.png na raiz do repositório) e tela de login
WALL_DIR=usr/share/wallpapers/HKOS
if [[ -f "$HERE/wallpaper.png" ]]; then
  mkdir -p "$AIROOT/$WALL_DIR/contents/images"
  cp "$HERE/wallpaper.png" "$AIROOT/$WALL_DIR/contents/images/1400x1008.png"
  put 644 "$WALL_DIR/metadata.json" <<'EOF'
{
  "KPlugin": {
    "Id": "HKOS",
    "Name": "HKOS",
    "Authors": [{ "Name": "HK Tech" }]
  }
}
EOF
  put 755 usr/local/bin/hkos-wallpaper <<'EOF'
#!/usr/bin/env bash
# Aplica o papel de parede HKOS uma única vez por usuário (depois ele escolhe o que quiser).
FLAG="$HOME/.config/hkos-wallpaper.done"
[[ -e "$FLAG" ]] && exit 0
IMG=/usr/share/wallpapers/HKOS/contents/images/1400x1008.png
for _ in $(seq 1 15); do
  if plasma-apply-wallpaperimage "$IMG" >/dev/null 2>&1; then
    mkdir -p "$(dirname "$FLAG")"; touch "$FLAG"; exit 0
  fi
  sleep 2
done
EOF
  sed -i '/^file_permissions=(/a\  ["/usr/local/bin/hkos-wallpaper"]="0:0:755"' "$PROFILE/profiledef.sh"
  put 644 etc/xdg/autostart/hkos-wallpaper.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=HKOS wallpaper
Exec=/usr/local/bin/hkos-wallpaper
X-KDE-autostart-phase=2
NoDisplay=true
EOF
  put 644 usr/share/sddm/themes/breeze/theme.conf.user <<'EOF'
[General]
type=image
background=/usr/share/wallpapers/HKOS/contents/images/1400x1008.png
EOF
  HAS_WALL=1
else
  echo "AVISO: wallpaper.png não encontrado; o HKOS ficará sem o papel de parede HK Tech." >&2
  HAS_WALL=0
fi
put 644 etc/sddm.conf.d/theme.conf <<'EOF'
[Theme]
Current=breeze
EOF

###############################################################################
# 6) SISTEMA: logs, coredump, timeouts, CPU, módulos, GameMode, sysctl
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
# CPU sempre em desempenho e discos/links sem economia de energia
w /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor - - - - performance
w /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference - - - - performance
w /sys/class/scsi_host/host*/link_power_management_policy - - - - max_performance
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
put 644 etc/environment.d/10-gameos.conf <<'EOF'
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
  etc/gamemode.ini
  etc/environment.d/10-gameos.conf
  etc/xdg/kdeglobals etc/xdg/kwinrc etc/xdg/baloofilerc
  etc/xdg/ksplashrc etc/xdg/kwalletrc etc/xdg/kscreenlockerrc
  etc/gtk-3.0/settings.ini etc/gtk-4.0/settings.ini
  etc/firefox/policies/policies.json
  usr/lib/systemd/system/gameos-firstboot.service
  etc/os-release etc/motd etc/sddm.conf.d/theme.conf
)
if [[ "$HAS_WALL" == 1 ]]; then
  SHIPPED+=(
    usr/share/wallpapers/HKOS/metadata.json
    usr/share/wallpapers/HKOS/contents/images/1400x1008.png
    usr/share/sddm/themes/breeze/theme.conf.user
    etc/xdg/autostart/hkos-wallpaper.desktop
  )
fi
mkdir -p "$AIROOT/usr/share/gameos"
printf '%s\n' "${SHIPPED[@]}" > "$AIROOT/usr/share/gameos/files.txt"
cp "$HERE/packages.extra" "$AIROOT/usr/share/gameos/packages.txt"

###############################################################################
# 7) INSTALADOR (archinstall + camada HKOS)
###############################################################################
put 755 usr/local/bin/hkos-install <<'INSTALLER_EOF'
#!/usr/bin/env bash
# HKOS - instalador: usa o archinstall e depois aplica o HKOS no sistema instalado.
set -euo pipefail
[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"

cat <<'EOF'

HKOS - instalador

 Passo 1: o archinstall vai abrir para você escolher disco, idioma, usuário e senha.
   - Perfil: escolha "Minimal" (os pacotes do HKOS entram no passo 2).
   - Kernel: escolha "linux-zen" (é o kernel otimizado do HKOS).
   - Repositórios adicionais: ative "multilib" (necessário para Steam).
   - Rede: "NetworkManager".
   - Quando terminar, NÃO reinicie e NÃO entre no chroot.

 Passo 2: este script instala os pacotes de jogos e os ajustes do HKOS.

 ATENÇÃO: o archinstall pode apagar o disco escolhido. Não escolha o disco do Windows
 se quiser mantê-lo.

EOF
read -rp "Continuar? [s/N] " resp
[[ "$resp" =~ ^[sSyY]$ ]] || exit 0

archinstall

if [[ ! -d /mnt/etc ]]; then
  echo "Não encontrei o sistema instalado em /mnt. O archinstall foi concluído?" >&2
  exit 1
fi

echo "==> Ativando multilib"
if ! grep -q '^\[multilib\]' /mnt/etc/pacman.conf; then
  sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /mnt/etc/pacman.conf
fi

echo "==> Instalando pacotes do HKOS (pode demorar)"
mapfile -t PKGS < <(grep -vE '^\s*(#|$)' /usr/share/gameos/packages.txt | grep -vx 'archinstall')
arch-chroot /mnt pacman -Syu --needed --noconfirm "${PKGS[@]}"

echo "==> Copiando ajustes de desempenho e debloat"
while read -r f; do
  [[ -n "$f" ]] && install -D -m 0644 "/$f" "/mnt/$f"
done < /usr/share/gameos/files.txt
install -D -m 0755 /usr/local/bin/gameos-firstboot /mnt/usr/local/bin/gameos-firstboot
[[ -f /usr/local/bin/hkos-wallpaper ]] && install -D -m 0755 /usr/local/bin/hkos-wallpaper /mnt/usr/local/bin/hkos-wallpaper
sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 10/' /mnt/etc/pacman.conf

echo "==> Montagem de disco sem atime"
sed -i 's/\brelatime\b/noatime/g' /mnt/etc/fstab

echo "==> Parâmetros do kernel (mitigations=off: mais FPS, menos proteção contra falhas de CPU)"
CMD='quiet loglevel=3 mitigations=off nowatchdog split_lock_detect=off audit=0 nvme_core.default_ps_max_latency_us=0 usbcore.autosuspend=-1'
if [[ -f /mnt/etc/default/grub ]]; then
  sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\1 $CMD\"|" /mnt/etc/default/grub
  arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg || true
fi
for e in /mnt/boot/loader/entries/*.conf; do
  [[ -f "$e" ]] && sed -i "/^options/ s|\$| $CMD|" "$e"
done

echo "==> Ativando serviços"
arch-chroot /mnt systemctl enable \
  NetworkManager.service bluetooth.service sddm.service \
  fstrim.timer gameos-firstboot.service
arch-chroot /mnt systemctl disable NetworkManager-wait-online.service || true

echo "==> Regenerando initramfs"
arch-chroot /mnt mkinitcpio -P

cat <<'EOF'

Instalação concluída. Remova o pendrive e reinicie.
No primeiro boot (com internet), o HKOS instala Heroic (Epic/GOG) e ProtonUp-Qt (Proton-GE).
Para o Battle.net: abra o Lutris e procure "Battle.net".

EOF
INSTALLER_EOF

[[ "${DRYRUN:-0}" == 1 ]] && { echo "dry-run ok: $PROFILE"; exit 0; }

###############################################################################
# 8) GERA A ISO
###############################################################################
mkarchiso -v -w "$WORK/work" -o "$OUT" "$PROFILE"
echo "ISO gerada em: $OUT"
ls -lh "$OUT"
