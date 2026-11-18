#!/usr/bin/env bash
# GameOS - monta o perfil archiso (baseado no releng) e gera a ISO.
# Precisa rodar como root dentro de um Arch Linux (ou de um container archlinux).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-/tmp/gameos-work}"
OUT="${OUT:-$HERE/out}"
PROFILE="$WORK/profile"
AIROOT="$PROFILE/airootfs"

[[ $EUID -eq 0 ]] || { echo "Rode como root." >&2; exit 1; }
command -v mkarchiso >/dev/null || pacman -Sy --noconfirm archiso

rm -rf "$WORK"
mkdir -p "$PROFILE" "$OUT"
cp -r /usr/share/archiso/configs/releng/. "$PROFILE/"

# 1) Arquivos do GameOS por cima do airootfs do releng
cp -rT "$HERE/airootfs" "$AIROOT"

# 2) Pacotes extras
grep -vE '^\s*(#|$)' "$HERE/packages.extra" >> "$PROFILE/packages.x86_64"

# 3) Repositório multilib (necessário para Steam e Wine 32 bits)
cat >> "$PROFILE/pacman.conf" <<'EOF'

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF

# 4) Identidade e permissões
sed -i \
  -e 's|^iso_name=.*|iso_name="gameos"|' \
  -e 's|^iso_label=.*|iso_label="GAMEOS_$(date +%Y%m)"|' \
  -e 's|^iso_application=.*|iso_application="GameOS Live/Install ISO"|' \
  -e '/^file_permissions=(/a\  ["/usr/local/bin/gameos-install"]="0:0:755"' \
  -e '/^file_permissions=(/a\  ["/usr/local/bin/gameos-firstboot"]="0:0:755"' \
  -e '/^file_permissions=(/a\  ["/etc/sudoers.d/10-gameos"]="0:0:440"' \
  "$PROFILE/profiledef.sh"

# Lista de pacotes disponível no live para o instalador
mkdir -p "$AIROOT/usr/share/gameos"
cp "$HERE/packages.extra" "$AIROOT/usr/share/gameos/packages.txt"

# 5) Usuário da sessão live (sem senha, entra direto no desktop)
grep -q '^gamer:' "$AIROOT/etc/passwd"  || echo 'gamer:x:1000:1000:GameOS Live:/home/gamer:/bin/bash' >> "$AIROOT/etc/passwd"
grep -q '^gamer:' "$AIROOT/etc/shadow"  || echo 'gamer::14871::::::' >> "$AIROOT/etc/shadow"
grep -q '^gamer:' "$AIROOT/etc/group"   || echo 'gamer:x:1000:' >> "$AIROOT/etc/group"
grep -q '^gamer:' "$AIROOT/etc/gshadow" || echo 'gamer:!::' >> "$AIROOT/etc/gshadow"

# 6) Serviços: troca systemd-networkd/iwd (releng) por NetworkManager
find "$AIROOT/etc/systemd/system" \( -name 'systemd-networkd*' -o -name 'iwd.service' \) -exec rm -f {} + 2>/dev/null || true

enable() { # enable <unit> <target>
  mkdir -p "$AIROOT/etc/systemd/system/$2.wants"
  ln -sf "/usr/lib/systemd/system/$1" "$AIROOT/etc/systemd/system/$2.wants/$1"
}
enable NetworkManager.service multi-user.target
enable bluetooth.service bluetooth.target
enable power-profiles-daemon.service graphical.target
ln -sf /usr/lib/systemd/system/sddm.service "$AIROOT/etc/systemd/system/display-manager.service"

# 7) Gera a ISO
mkarchiso -v -w "$WORK/work" -o "$OUT" "$PROFILE"
echo "ISO gerada em: $OUT"
ls -lh "$OUT"
