#!/usr/bin/env bash
set -Eeuo pipefail

# save normal stdout as FD 3 (so we can output *only* our final markdown there), and copy stderr to stdout so any other script output goes to stderr (and thus our markdown output can be very explicit)
exec 3>&1 1>&2

#trap 'echo >&2 Ctrl+C captured, exiting; exit 1' INT TERM

image="$1"; shift

# so we get an error message quickly if we don't have the image-under-test
id="$(docker image inspect --format '{{ .Id }}' "$image")"

# for this problem, it's tempting to just let buildkit manage pulling/using the image-under-test, but we need to also collect metadata from the image itself (via docker image inspect), because this is a metadata-collection exercise, so we do need the image we're passing to buildkit to also exist locally, and we need some way to be absolutely certain that "docker image inspect" and "docker buildx build" use the exact same image, and there's not (as of 2025-03-11) a supported way to do that other than "docker save" -> an OCI layout (including Tianon's shim script because older versions of Docker don't output an OCI layout)
if ! sha256sum <<<'baca98f706f58f6be5c327ce9b3ab7290b917b31dd7b354d397d28d2ce6fff97 *.docker-save-oci-layout.sh' --strict --check -; then
	# https://github.com/tianon/docker-bin/blob/master/docker-save-oci-layout.sh
	wget -O .docker-save-oci-layout.sh 'https://github.com/tianon/docker-bin/raw/aef2b35350eabe4748dddda3ccc0ddf02ad1526e/docker-save-oci-layout.sh'
fi
chmod +x .docker-save-oci-layout.sh

tmp="$(mktemp --directory 'repo-info-local.XXXXXXXXXX')"
trap "$(printf 'rm -rf %q' "$tmp")" EXIT
tmp="$(cd "$tmp" && pwd -P)" # absolutize tmp

./.docker-save-oci-layout.sh "$tmp/oci" "$id"

# ideally, we'd use --iidfile here so that we don't have to rely on image tagging weirdness and our images could be naturally "dangling" and thus obviously ripe for cleanup, but it has a cute bug when combined with the containerd integration that it puts the config digest in the file instead of the manifest digest, so it's not usable as the image ID after the build completes
# we *could* do something like --output type=oci,... into our $tmp directory, but that's not great either 🙃 (because ultimately we do want to run it later)
tag="repo-info/$image"
docker buildx build \
	--pull \
	--load \
	--provenance=false \
	--build-context "image=oci-layout://$tmp/oci" \
	--file 'Dockerfile.local' \
	--tag "$tag" \
	.
iid="$(docker image inspect --format '{{ .Id }}' "$tag")" # again, ideally this would be reading an iidfile we saved in $tmp 🙃

# Docker historically presents sizes in "SI" units (1000-based), but those are rubbish, so we'll present both instead
size="$(docker image inspect --format '{{ .VirtualSize }}' "$id")"
# TODO decide how to handle the containerd integration here, because VirtualSize is now the compressed size, which completely defeats the purpose of even presenting this information here 😕
iec="$(awk <<<"$size" '{
	k = 1024;
	m = k * k;
	g = k * k * k;
	if ($1 >= g) {
		printf "~ %.2f GiB", $1 / g
	} else if ($1 >= m) {
		printf "~ %.2f MiB", $1 / m
	} else if ($1 >= k) {
		printf "~ %.2f KiB", $1 / k
	} else {
		printf "%d bytes", $1
	}
}')"
si="$(awk <<<"$size" '{
	k = 1000;
	m = k * k;
	g = k * k * k;
	if ($1 >= g) {
		printf "~ %.2f GB", $1 / g
	} else if ($1 >= m) {
		printf "~ %.2f MB", $1 / m
	} else if ($1 >= k) {
		printf "~ %.2f kB", $1 / k
	} else {
		printf "%d bytes", $1
	}
}')"
size="$si"
if [ "$iec" != "$si" ]; then
	size+=" ($iec)"
fi

>&3 docker inspect -f '# `'"$image"'`

## Docker Metadata

- Image ID: `{{ .Id }}`
- Created: `{{ .Created }}`
- Virtual Size: '"$size"'  
  (total size of all layers on-disk)
- Arch: `{{ .Os }}`/`{{ .Architecture }}`
{{ if .Config.Entrypoint }}- Entrypoint: `{{ json .Config.Entrypoint }}`
{{ end }}{{ if .Config.Cmd }}- Command: `{{ json .Config.Cmd }}`
{{ end }}- Environment:{{ range .Config.Env }}{{ "\n" }}  - `{{ . }}`{{ end }}{{ if .Config.Labels }}
- Labels:{{ range $k, $v := .Config.Labels }}{{ "\n" }}  - `{{ $k }}={{ $v }}`{{ end }}{{ end }}' "$image"

# if this comes back empty, we need to error (with explicit exceptions for things like "hello-world")
lines="$(docker run --rm "$iid" find -name '*.md' -exec cat '{}' + | tee -a /dev/fd/3 | wc -l)"

if [ "$lines" = 0 ]; then
	# TODO add exceptions
	echo >&2 "error: '$image' failed to scan (no results)"
	exit 1
fi
