#!/bin/bash

# Copyright Istio Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

VERSIONS_YAML_FILE=${VERSIONS_YAML_FILE:-"versions.yaml"}
VERSIONS_YAML_DIR=${VERSIONS_YAML_DIR:-"pkg/istioversion"}

: "${YQ:=yq}"

# Map containing all components
declare -A COMPONENTS=( 
  ["istiod"]="pilot"
  ["proxy"]="proxy"
  ["cni"]="cni"
  ["ztunnel"]="ztunnel"
)

function is_empty_or_null() {
  if [ $# -ne 1 ]; then
    echo "Usage: is_empty_or_null <field>"
    exit 1
  fi
  field="${1}"
  [ -z "${field}" ] || [ "${field}" = "null" ]
}

function get_field() {
  if [ $# -ne 3 ]; then
    echo "Usage: get_field <version> <field_name> <component_name>"
    exit 1
  fi

  local version="${1}"
  local field_name="${2}"
  local component_name="${3}"

  component_dir="${component_name}"
  if [ "${component_name}" = "proxy" ]; then
    component_dir="istiod"
  fi

  # The following code tries to find the field in several places:

  # 1) .defaults.<component>.<field>
  field="$(${YQ} ".defaults.${COMPONENTS[$component_name]}.${field_name}" "resources/${version}/charts/${component_dir}/values.yaml")"
  # 2) .defaults.global.<component>.<field>
  if is_empty_or_null "${field}"; then
    field="$(${YQ} ".defaults.global.${COMPONENTS[$component_name]}.${field_name}" "resources/${version}/charts/${component_dir}/values.yaml")"
  fi
  # 3) .defaults.<field>
  if is_empty_or_null "${field}"; then
    field="$(${YQ} ".defaults.${field_name}" "resources/${version}/charts/${component_dir}/values.yaml")"
  fi
  # 4) .defaults.global.<field>
  if is_empty_or_null "${field}"; then
    field="$(${YQ} ".defaults.global.${field_name}" "resources/${version}/charts/${component_dir}/values.yaml")"
  fi
  # 5) ._internal_defaults_do_not_set.<component>.<field>
  if is_empty_or_null "${field}"; then
      field="$(${YQ} "._internal_defaults_do_not_set.${COMPONENTS[$component_name]}.${field_name}" "resources/${version}/charts/${component_dir}/values.yaml")"
  fi
  # 6) ._internal_defaults_do_not_set.global.<component>.<field>
  if is_empty_or_null "${field}"; then
    field="$(${YQ} "._internal_defaults_do_not_set.global.${COMPONENTS[$component_name]}.${field_name}" "resources/${version}/charts/${component_dir}/values.yaml")"
  fi
  # 7) ._internal_defaults_do_not_set.<field>
  if is_empty_or_null "${field}"; then
    field="$(${YQ} "._internal_defaults_do_not_set.${field_name}" "resources/${version}/charts/${component_dir}/values.yaml")"
  fi
  # 8) ._internal_defaults_do_not_set.global.<field>
  if is_empty_or_null "${field}"; then
    field="$(${YQ} "._internal_defaults_do_not_set.global.${field_name}" "resources/${version}/charts/${component_dir}/values.yaml")"
  fi

  if is_empty_or_null "${field}"; then
    field=""
  fi
  echo "${field}"
}

## MAIN
if [ $# -ne 1 ]; then
  echo "Usage: $0 <values_file_path>"
  exit 1
fi
values_file_path="$1"

versions="$( ${YQ} '.versions[] | select(. | has("ref") | not) | select (.eol != true) | .name' "${VERSIONS_YAML_DIR}/${VERSIONS_YAML_FILE}" )"

# remove existing images to always generate a fresh list
${YQ} -i '.deployment.annotations = {}' "${values_file_path}"
for version in ${versions}; do
  version_underscore=${version//./_}
  for component_name in "${!COMPONENTS[@]}"; do
    name="${version_underscore}.${component_name}"
    hub=$(get_field "${version}" "hub" "${component_name}")
    image=$(get_field "${version}" "image" "${component_name}")
    tag=$(get_field "${version}" "tag" "${component_name}")

    if [ -z "${hub}" ] || [ -z "${image}" ] || [ -z "${tag}" ]; then
      echo "Missing hub, image or tag for version ${version}, component ${component_name}"
      exit 1
    fi

    ${YQ} -i '.deployment.annotations |= (. + {"images.'"${name}"'": "'"${hub}"'/'"${image}"':'"${tag}"'"})' "${values_file_path}"
  done
done
