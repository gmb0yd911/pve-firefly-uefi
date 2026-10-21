#!/usr/bin/env bash
# Hold VOP clocks through UEFI handoff (validated with vendor 6.1.115).
# Uses the same regulator-fixed-clock mechanism as EDK2's GOP preservation,
# while leaving native DRM nodes enabled. Does not install or select a boot.
set -euo pipefail

if [[ $# != 2 ]]; then
  echo "Usage: $0 INPUT.dtb OUTPUT.dtb" >&2
  exit 2
fi

input=$1
output=$2
[[ $input != "$output" ]] || { echo "Use a separate output file" >&2; exit 2; }
[[ ! -e $output ]] || { echo "Output already exists: $output" >&2; exit 2; }

read -r -a names <<< "$(fdtget -t s "$input" /vop@fdd90000 clock-names)"
read -r -a cells <<< "$(fdtget -t x "$input" /vop@fdd90000 clocks)"
cru=$(fdtget -t x "$input" /clock-controller@fd7c0000 phandle)
[[ ${#cells[@]} == $((${#names[@]} * 2)) ]] || {
  echo "Unexpected VOP clock specifier layout" >&2; exit 1;
}

temporary=$(mktemp "${output}.tmp.XXXXXX")
trap 'rm -f "$temporary"' EXIT
cp "$input" "$temporary"

for wanted in aclk_vop hclk_vop dclk_vp0 dclk_vp1 dclk_vp2 dclk_vp3 pclk_vop; do
  found=false
  for index in "${!names[@]}"; do
    [[ ${names[index]} == "$wanted" ]] || continue
    [[ ${cells[index * 2]} == "$cru" ]] || {
      echo "Unexpected provider for $wanted" >&2; exit 1;
    }
    node="/uefi-keep-${wanted//_/-}"
    fdtput -c "$temporary" "$node"
    fdtput -t s "$temporary" "$node" compatible regulator-fixed-clock
    fdtput -t s "$temporary" "$node" regulator-name "uefi-keep-$wanted"
    fdtput "$temporary" "$node" regulator-always-on
    fdtput -t x "$temporary" "$node" clocks "$cru" "${cells[index * 2 + 1]}"
    found=true
    break
  done
  $found || { echo "Missing VOP clock: $wanted" >&2; exit 1; }
done

mv "$temporary" "$output"
echo "Built UEFI display clock-hold DTB: $output"
