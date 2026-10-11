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

{{- /* Service names are DNS labels (63 characters at most); the fullname's
     52-character cap (validatePod) leaves room for either suffix. */}}
{{- define "decdn-node.metricsServiceName" -}}
{{- printf "%s-metrics" (include "decdn-node.fullname" .) }}
{{- end }}

{{- define "decdn-node.headlessServiceName" -}}
{{- printf "%s-headless" (include "decdn-node.fullname" .) }}
{{- end }}

{{- define "decdn-node.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "decdn-node.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* ---------------------------------------------------------------------------
Image: the digest when set, else the tag, which defaults to appVersion.
--------------------------------------------------------------------------- */}}
{{- define "decdn-node.image" -}}
{{- $img := .Values.image }}
{{- if $img.digest }}
{{- printf "%s@%s" $img.repository $img.digest }}
{{- else }}
{{- printf "%s:%s" $img.repository (default .Chart.AppVersion $img.tag) }}
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
{{- /* Read-only, from origin.volume: an fs origin's content (Compose's path too). */}}
{{- define "decdn-node.originDir" -}}/srv/decdn-origin{{- end }}

{{/* origin.volume's source with readOnly forced on, for every source that has the
field. The mount's readOnly alone does not stop the kubelet applying fsGroup
ownership (a recursive chgrp) to a PVC or CSI volume: it reads the source's flag. */}}
{{- define "decdn-node.originVolume" -}}
{{- $v := deepCopy (default (dict) (get (default (dict) .Values.origin) "volume")) }}
{{- range $src := list "persistentVolumeClaim" "csi" "nfs" "iscsi" "rbd" "cephfs" "fc" }}
{{- if kindIs "map" (get $v $src) }}
{{- $_ := set (get $v $src) "readOnly" true }}
{{- end }}
{{- end }}
{{- toYaml $v }}
{{- end }}

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
Pod-level overrides that would silently break a chart invariant. Fail loud rather
than let a values override win:
- a full name over 52 characters (the StatefulSet could create no pod);
- podLabels re-setting a chart label (the selector labels would detach the pod
  from the StatefulSet and Services);
- podAnnotations re-setting checksum/config (config changes would stop rolling),
  or carrying the legacy AppArmor/seccomp annotations, which Kubernetes still
  honours and which would bypass the profile checks below;
- a (pod)securityContext that drops the non-root / no-privilege /
  read-only-rootfs / all-capabilities-dropped / confined (seccomp, AppArmor,
  masked /proc) hardening, at either level (compared as strings: `get`
  yields "" for a missing key, which `eq` cannot compare with a bool). Helm merges overrides
  into the defaults, so these must hold on the merged values, and a `null` that
  removes one of them fails too: no seccomp profile at either level means
  Unconfined (the kubelet's default), and no runAsGroup means gid 0 for a uid the
  image has no passwd entry for.
--------------------------------------------------------------------------- */}}
{{- define "decdn-node.validatePod" -}}
{{- $fullname := include "decdn-node.fullname" . }}
{{- if gt (len $fullname) 52 }}
{{- fail (printf "the full name %q is %d characters; a StatefulSet's pods need 52 or fewer (Kubernetes labels each pod with <name>-<revision hash>, 63 characters at most): use a shorter release name or fullnameOverride" $fullname (len $fullname)) }}
{{- end }}
{{- $chartLabels := include "decdn-node.labels" . | fromYaml }}
{{- range $k, $_ := default (dict) .Values.podLabels }}
{{- if hasKey $chartLabels $k }}
{{- fail (printf "podLabels.%s is set by the chart and must not be overridden" $k) }}
{{- end }}
{{- end }}
{{- if hasKey (default (dict) .Values.podAnnotations) "checksum/config" }}
{{- fail "podAnnotations.checksum/config is set by the chart (it rolls the pod on config changes) and must not be overridden" }}
{{- end }}
{{- range $k, $_ := default (dict) .Values.podAnnotations }}
{{- range $legacy := list "container.apparmor.security.beta.kubernetes.io/" "seccomp.security.alpha.kubernetes.io/" "container.seccomp.security.alpha.kubernetes.io/" }}
{{- if hasPrefix $legacy $k }}
{{- fail (printf "podAnnotations.%s is refused: the legacy AppArmor/seccomp annotations would bypass the chart's checks; set the profile in (pod)securityContext instead" $k) }}
{{- end }}
{{- end }}
{{- end }}
{{- $psc := default (dict) .Values.podSecurityContext }}
{{- if not (eq (toString (get $psc "runAsNonRoot")) "true") }}
{{- fail "podSecurityContext.runAsNonRoot must be true" }}
{{- end }}
{{- range $f := list "runAsUser" "runAsGroup" "fsGroup" }}
{{- if and (hasKey $psc $f) (eq (int (get $psc $f)) 0) }}
{{- fail (printf "podSecurityContext.%s must not be 0 (root)" $f) }}
{{- end }}
{{- end }}
{{- range (default (list) (get $psc "supplementalGroups")) }}
{{- if eq (int .) 0 }}
{{- fail "podSecurityContext.supplementalGroups must not contain 0 (root)" }}
{{- end }}
{{- end }}
{{- $sc := default (dict) .Values.securityContext }}
{{- /* A container-level profile overrides the pod's, so both levels are checked. */}}
{{- range $ctx := list (list "podSecurityContext" $psc) (list "securityContext" $sc) }}
{{- range $p := list "seccompProfile" "appArmorProfile" }}
{{- $prof := get (index $ctx 1) $p }}
{{- if and (hasKey (index $ctx 1) $p) (not (kindIs "invalid" $prof)) (not (kindIs "map" $prof)) }}
{{- fail (printf "%s.%s must be a map with a `type`, got %s" (index $ctx 0) $p (kindOf $prof)) }}
{{- end }}
{{- if eq (toString (dig $p "type" "" (index $ctx 1))) "Unconfined" }}
{{- fail (printf "%s.%s.type must not be Unconfined" (index $ctx 0) $p) }}
{{- end }}
{{- end }}
{{- end }}
{{- $seccomp := default (toString (dig "seccompProfile" "type" "" $psc)) (toString (dig "seccompProfile" "type" "" $sc)) }}
{{- if not (has $seccomp (list "RuntimeDefault" "Localhost")) }}
{{- fail "seccompProfile.type must be RuntimeDefault or Localhost (securityContext, else podSecurityContext): with no profile the container runs Unconfined" }}
{{- end }}
{{- if not (or (and (hasKey $sc "runAsGroup") (not (kindIs "invalid" (get $sc "runAsGroup")))) (and (hasKey $psc "runAsGroup") (not (kindIs "invalid" (get $psc "runAsGroup"))))) }}
{{- fail "runAsGroup must be set (podSecurityContext or securityContext): a uid the image has no passwd entry for would otherwise run with gid 0" }}
{{- end }}
{{- if not (eq (toString (get $sc "allowPrivilegeEscalation")) "false") }}
{{- fail "securityContext.allowPrivilegeEscalation must be false" }}
{{- end }}
{{- if not (eq (toString (get $sc "readOnlyRootFilesystem")) "true") }}
{{- fail "securityContext.readOnlyRootFilesystem must be true" }}
{{- end }}
{{- if eq (toString (get $sc "privileged")) "true" }}
{{- fail "securityContext.privileged must not be true" }}
{{- end }}
{{- if or (eq (toString (get $sc "runAsNonRoot")) "false") (and (hasKey $sc "runAsUser") (eq (int (get $sc "runAsUser")) 0)) }}
{{- fail "securityContext must not run as root (runAsNonRoot=false or runAsUser=0)" }}
{{- end }}
{{- if and (hasKey $sc "runAsGroup") (eq (int (get $sc "runAsGroup")) 0) }}
{{- fail "securityContext.runAsGroup must not be 0 (root)" }}
{{- end }}
{{- if eq (toString (get $sc "procMount")) "Unmasked" }}
{{- fail "securityContext.procMount must not be Unmasked" }}
{{- end }}
{{- $caps := default (dict) (get $sc "capabilities") }}
{{- if not (has "ALL" (default (list) (get $caps "drop"))) }}
{{- fail "securityContext.capabilities.drop must include ALL" }}
{{- end }}
{{- if get $caps "add" }}
{{- fail "securityContext.capabilities.add must be empty: the node needs no Linux capabilities" }}
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

{{- /* Upstream's validate_port_layout (decdn crates/common/src/config/mod.rs):
     QUIC, metrics and admin ports pairwise distinct, so fail before the pod
     crash-loops. QUIC (UDP) could share a number with a TCP port without a bind
     clash, but the daemon refuses it as a typo; metrics and admin (both TCP) would
     clash outright. admin_port defaults to 9191; 0 disables the admin RPC. */}}
{{- $ports := list (list "quic.port" (int $root.Values.quic.port)) (list "metrics.port" (int $root.Values.metrics.port)) }}
{{- $adminRaw := dig "admin_port" 9191 $cfg.observability }}
{{- if not (or (kindIs "float64" $adminRaw) (kindIs "int64" $adminRaw) (kindIs "int" $adminRaw)) }}
{{- fail (printf "config.observability.admin_port must be a number (0 disables the admin RPC), got %s %q" (kindOf $adminRaw) (toString $adminRaw)) }}
{{- end }}
{{- $admin := int $adminRaw }}
{{- if ne $admin 0 }}
{{- $ports = append $ports (list "config.observability.admin_port" $admin) }}
{{- end }}
{{- range $i, $a := $ports }}
{{- range $j, $b := $ports }}
{{- if and (lt $i $j) (eq (index $a 1) (index $b 1)) }}
{{- fail (printf "%s and %s are both %d: the daemon refuses a shared port number" (index $a 0) (index $b 0) (index $a 1)) }}
{{- end }}
{{- end }}
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
{{- /* An fs origin reads origin.volume, mounted read-only at originDir: its path
     must lie there, and the volume must exist and be used. */}}
{{- $originDir := include "decdn-node.originDir" $root }}
{{- $originValues := default (dict) $root.Values.origin }}
{{- $originVolume := get $originValues "volume" }}
{{- if and (get $originValues "subPath") (not $originVolume) }}
{{- fail "origin.subPath is set without origin.volume: it selects a directory of that volume" }}
{{- end }}
{{- $origins := ternary (list (get $cache "origin")) (default (list) (get $cache "origins")) $hasOrigin }}
{{- $fsOrigins := 0 }}
{{- range $origins }}
{{- if and (kindIs "map" .) (eq (toString (get . "kind")) "fs") }}
{{- $fsOrigins = add1 $fsOrigins }}
{{- if or (not (hasKey . "path")) (kindIs "invalid" (get . "path")) }}
{{- fail (printf "config.cache: an fs origin needs a path, %s or a directory under it" $originDir) }}
{{- end }}
{{- $path := toString (get . "path") }}
{{- if or (not (or (eq $path $originDir) (hasPrefix (printf "%s/" $originDir) $path))) (regexMatch "(^|/)\\.\\.(/|$)" $path) }}
{{- fail (printf "config.cache: an fs origin's path must be %s or a directory under it, where origin.volume is mounted (got %q)" $originDir $path) }}
{{- end }}
{{- if not $originVolume }}
{{- fail (printf "config.cache: an fs origin needs origin.volume, the volume holding its content (mounted read-only at %s)" $originDir) }}
{{- end }}
{{- end }}
{{- end }}
{{- if and $originVolume (eq $fsOrigins 0) }}
{{- fail "origin.volume is set, but no config.cache origin has kind fs: remove it, or add the fs origin that reads it" }}
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
