{{/* ---------------------------------------------------------------------------
Names and labels
--------------------------------------------------------------------------- */}}
{{- define "decdn-node.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "decdn-node.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "decdn-node.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "decdn-node.selectorLabels" -}}
app.kubernetes.io/name: {{ include "decdn-node.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "decdn-node.labels" -}}
helm.sh/chart: {{ include "decdn-node.chart" . }}
{{ include "decdn-node.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "decdn-node.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "decdn-node.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* ---------------------------------------------------------------------------
Image. Upstream has no release (appVersion 0.0.0 is a placeholder), so an
unpinned render would reference an image that does not exist: fail loud.
--------------------------------------------------------------------------- */}}
{{- define "decdn-node.image" -}}
{{- $img := .Values.image }}
{{- if $img.digest }}
{{- printf "%s@%s" $img.repository $img.digest }}
{{- else }}
{{- $tag := default .Chart.AppVersion $img.tag }}
{{- if eq $tag "0.0.0" }}
{{- fail "image: upstream decdn has published no release image yet; set image.tag or image.digest (e.g. a locally built image of decdn/Dockerfile)" }}
{{- end }}
{{- printf "%s:%s" $img.repository $tag }}
{{- end }}
{{- end }}

{{/* ---------------------------------------------------------------------------
In-pod paths. data_dir is a SUBDIRECTORY of the PVC mount: the mount root carries
fsGroup bits, and upstream refuses a data_dir with any group/world permission.
--------------------------------------------------------------------------- */}}
{{- define "decdn-node.dataMount" -}}/var/lib/decdn{{- end }}
{{- define "decdn-node.dataDir" -}}/var/lib/decdn/node{{- end }}
{{- define "decdn-node.cacheDir" -}}/var/lib/decdn/node/cache{{- end }}
{{- define "decdn-node.configFile" -}}/etc/decdn/node.toml{{- end }}
{{- /* In-memory (emptyDir medium: Memory): the keystore password, off the PVC. */}}
{{- define "decdn-node.secretsDir" -}}/run/decdn{{- end }}

{{/* ---------------------------------------------------------------------------
Required Secret references (the chart never creates a Secret).
--------------------------------------------------------------------------- */}}
{{- define "decdn-node.validateSecrets" -}}
{{- if not .Values.secrets.keystore.existingSecret }}
{{- fail "secrets.keystore.existingSecret is required: a Secret holding keystore.json, node.secret and keystore.password from `decdn key-gen` (see the chart README)" }}
{{- end }}
{{- if not .Values.secrets.env.existingSecret }}
{{- fail "secrets.env.existingSecret is required: a Secret holding DECDN_RPC_URL (see the chart README)" }}
{{- end }}
{{- range .Values.secrets.env.passthroughKeys }}
{{- if hasPrefix "DECDN_" (upper .) }}
{{- fail (printf "secrets.env.passthroughKeys: %s is refused: DECDN_* env overrides node.toml and would bypass the chart's managed keys and checks; set it in config instead" .) }}
{{- end }}
{{- end }}
{{- end }}

{{/* ---------------------------------------------------------------------------
Refuse secret-bearing keys anywhere in `config`. node.toml lands in a ConfigMap,
which is readable by anyone with get on configmaps in the namespace.
Arg: dict "node" <map|list|scalar> "path" <string>
--------------------------------------------------------------------------- */}}
{{- define "decdn-node.forbidSecretKeys" -}}
{{- $node := .node }}
{{- if kindIs "map" $node }}
{{- range $k, $v := $node }}
{{- $here := ternary $k (printf "%s.%s" $.path $k) (eq $.path "") }}
{{- $lk := lower $k | replace "-" "_" }}
{{- if or (has $lk (list "rpc_url" "access_key_id" "session_token")) (contains "password" $lk) (contains "secret" $lk) }}
{{- fail (printf "config.%s: secret-bearing keys must not be set in config (it renders to a ConfigMap); put DECDN_RPC_URL and other secrets in secrets.env.existingSecret" $here) }}
{{- end }}
{{- include "decdn-node.forbidSecretKeys" (dict "node" $v "path" $here) }}
{{- end }}
{{- else if kindIs "slice" $node }}
{{- range $node }}
{{- include "decdn-node.forbidSecretKeys" (dict "node" . "path" $.path) }}
{{- end }}
{{- end }}
{{- end }}

{{/* ---------------------------------------------------------------------------
Build the effective node.toml tree IN PLACE on .cfg (a deep copy of
.Values.config): chart-managed keys + derived defaults. Fails on non-table
sections, managed-key collisions and cross-field errors. (Mutating in place just
avoids a JSON round-trip; numbers from values files are float64 regardless, which
decdn-node.toml.value handles.)
Arg: dict "cfg" <map> "root" <$>
--------------------------------------------------------------------------- */}}
{{- define "decdn-node.config" -}}
{{- $cfg := .cfg }}
{{- $root := .root }}
{{- include "decdn-node.forbidSecretKeys" (dict "node" $cfg "path" "") }}
{{- /* Every top-level node.toml entry is a table. A scalar here would either be
     replaced by the managed-key injection below or rendered as a bare top-level
     key the daemon rejects — both silently wrong at render time. */}}
{{- range $section, $v := $cfg }}
{{- if not (kindIs "map" $v) }}
{{- fail (printf "config.%s must be a table (map), got %s" $section (kindOf $v)) }}
{{- end }}
{{- end }}

{{- /* [section, key, managed value, what to set instead (hint)] */}}
{{- $managed := list
  (list "identity" "data_dir" (include "decdn-node.dataDir" $root) "(fixed by the chart)")
  (list "blockchain" "eth_keystore" (printf "%s/keystore.json" (include "decdn-node.dataDir" $root)) "secrets.keystore")
  (list "cache" "cache_dir" (include "decdn-node.cacheDir" $root) "(fixed by the chart)")
  (list "network" "bind_port" (int $root.Values.quic.port) "quic.port")
  (list "observability" "metrics_port" (int $root.Values.metrics.port) "metrics.port")
  (list "observability" "metrics_bind" "0.0.0.0" "(fixed by the chart; reach is limited by the NetworkPolicy)")
}}
{{- range $managed }}
{{- $section := index . 0 }}
{{- $key := index . 1 }}
{{- $table := default (dict) (get $cfg $section) }}
{{- if hasKey $table $key }}
{{- fail (printf "config.%s.%s is managed by the chart and must not be set; use %s" $section $key (index . 3)) }}
{{- end }}
{{- $_ := set $table $key (index . 2) }}
{{- $_ := set $cfg $section $table }}
{{- end }}

{{- $cache := $cfg.cache }}
{{- /* cache always exists: the managed cache_dir was just set on it */}}
{{- $hasOrigin := not (empty (get $cache "origin")) }}
{{- $hasOrigins := not (empty (get $cache "origins")) }}
{{- if and (hasKey $cache "origins") (not $hasOrigins) }}
{{- fail "config.cache.origins must not be empty: omit it for a node with no origin" }}
{{- end }}
{{- if and $hasOrigin $hasOrigins }}
{{- fail "config.cache.origin and config.cache.origins are mutually exclusive" }}
{{- end }}
{{- /* Ported from the decdn_node role (0f58d03): a node with no origin can only
     fill a miss from other nodes, so pull-through defaults on; with an origin, off. */}}
{{- if not (hasKey $cache "node_to_node_pull_through_enabled") }}
{{- $_ := set $cache "node_to_node_pull_through_enabled" (not (or $hasOrigin $hasOrigins)) }}
{{- end }}
{{- if and (hasKey $cache "max_blob_size_mb") (hasKey $cache "cache_size_mb") }}
{{- if gt (float64 $cache.max_blob_size_mb) (float64 $cache.cache_size_mb) }}
{{- fail "config.cache.max_blob_size_mb must be <= config.cache.cache_size_mb" }}
{{- end }}
{{- end }}
{{- end }}

{{/* ---------------------------------------------------------------------------
TOML rendering. Helm's toToml is not used: values decode YAML integers as
float64, which it would emit as `10240.0` and serde integer fields reject.
--------------------------------------------------------------------------- */}}

{{/* A TOML key: bare when it can be, JSON-quoted otherwise. */}}
{{- define "decdn-node.toml.key" -}}
{{- if regexMatch "^[A-Za-z0-9_-]+$" . }}{{ . }}{{ else }}{{ toJson . }}{{ end }}
{{- end }}

{{/* A scalar or array-of-scalars value. Whole numbers render as integers.
Values files decode every number as float64, which is exact only below 2^53:
anything larger would render rounded (or wrapped past int64) with no error. */}}
{{- define "decdn-node.toml.value" -}}
{{- $v := . }}
{{- if kindIs "slice" $v }}
{{- $items := list }}
{{- range $v }}
{{- $items = append $items (include "decdn-node.toml.value" .) }}
{{- end }}
{{- printf "[%s]" (join ", " $items) }}
{{- else if kindIs "bool" $v }}
{{- ternary "true" "false" $v }}
{{- else if or (kindIs "float64" $v) (kindIs "float32" $v) }}
{{- if or (ge (float64 $v) 9007199254740992.0) (le (float64 $v) -9007199254740992.0) }}
{{- fail (printf "config: %v is too large to render exactly (values are float64; limit 2^53)" $v) }}
{{- end }}
{{- if eq (floor $v) (float64 $v) }}{{ int64 $v }}{{ else }}{{ $v }}{{ end }}
{{- else if or (kindIs "int" $v) (kindIs "int64" $v) (kindIs "int32" $v) (kindIs "uint64" $v) }}
{{- $v }}
{{- else if kindIs "string" $v }}
{{- toJson $v }}
{{- else }}
{{- fail (printf "config: cannot render value %v (%s) as TOML" $v (kindOf $v)) }}
{{- end }}
{{- end }}

{{/* True ("true") when v is a non-empty list whose elements are maps. */}}
{{- define "decdn-node.toml.isTableArray" -}}
{{- if and (kindIs "slice" .) (gt (len .) 0) (kindIs "map" (first .)) }}true{{ end }}
{{- end }}

{{/*
One table body and everything beneath it. Scalars first (a scalar emitted below
a sub-table header would silently nest into that sub-table), then sub-tables,
then arrays of tables. A `[x]` header is emitted only for a table that carries
scalars or is empty, so pure intermediates (`[dht]` above `[dht.rate_limit]`) stay
implicit; a `[[x]]` header is always emitted (each one starts a new element).
Arg: dict "table" <map> "path" <dotted header path> "header" <"" | "[x]" | "[[x]]">
*/}}
{{- define "decdn-node.toml.table" -}}
{{- $t := .table }}
{{- $scalars := list }}
{{- $tables := list }}
{{- $arrays := list }}
{{- range $k := keys $t | sortAlpha }}
{{- $v := get $t $k }}
{{- if kindIs "invalid" $v }}
{{- /* null: Helm already strips top-level nulls; one inside a list element would
     otherwise vanish silently */}}
{{- fail (printf "config.%s: null inside a list element; omit the key instead" (ternary $k (printf "%s.%s" $.path $k) (eq $.path ""))) }}
{{- else if kindIs "map" $v }}
{{- $tables = append $tables $k }}
{{- else if include "decdn-node.toml.isTableArray" $v }}
{{- $arrays = append $arrays $k }}
{{- else }}
{{- $scalars = append $scalars $k }}
{{- end }}
{{- end }}
{{- if and .header (or $scalars (and (not $tables) (not $arrays)) (hasPrefix "[[" .header)) }}

{{ .header }}
{{- end }}
{{- range $scalars }}
{{ include "decdn-node.toml.key" . }} = {{ include "decdn-node.toml.value" (get $t .) }}
{{- end }}
{{- range $tables }}
{{- $p := ternary (include "decdn-node.toml.key" .) (printf "%s.%s" $.path (include "decdn-node.toml.key" .)) (eq $.path "") }}
{{- $body := include "decdn-node.toml.table" (dict "table" (get $t .) "path" $p "header" (printf "[%s]" $p)) }}
{{- $body }}
{{- end }}
{{- range $arrays }}
{{- $p := ternary (include "decdn-node.toml.key" .) (printf "%s.%s" $.path (include "decdn-node.toml.key" .)) (eq $.path "") }}
{{- range (get $t .) }}
{{- if not (kindIs "map" .) }}
{{- fail (printf "config.%s: every element of an array of tables must be a map" $p) }}
{{- end }}
{{- include "decdn-node.toml.table" (dict "table" . "path" $p "header" (printf "[[%s]]" $p)) }}
{{- end }}
{{- end }}
{{- end }}

{{- define "decdn-node.nodeToml" -}}
# Rendered by the decdn-node Helm chart. Do not edit in-cluster; change values.
{{- $cfg := deepCopy (default (dict) .Values.config) }}
{{- include "decdn-node.config" (dict "cfg" $cfg "root" .) }}
{{- include "decdn-node.toml.table" (dict "table" $cfg "path" "" "header" "") }}
{{- end }}
