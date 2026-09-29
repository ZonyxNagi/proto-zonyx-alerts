#!/bin/sh

# Check formatting (run 'buf format -w' to fix)
cmd="buf format --exit-code -d"
echo "Running '$cmd'"
$cmd

status=$?

if [ "$status" != 0 ]
then
	echo "Error: $cmd failed"
	exit 1
fi

# Check lint
cmd="buf lint"
echo "Running '$cmd'"
$cmd

status=$?

if [ "$status" != 0 ]
then
	echo "Error: $cmd failed"
	exit 1
fi

# Check breaking changes against a git reference, e.g.
# BREAKING_AGAINST='.git#branch=master' ./scripts/generate.sh
if [ -n "$BREAKING_AGAINST" ]
then
	cmd="buf breaking --against $BREAKING_AGAINST"
	echo "Running '$cmd'"
	$cmd

	status=$?

	if [ "$status" != 0 ]
	then
		echo "Error: $cmd failed"
		exit 1
	fi
fi

# Generate output and docs (buf.gen.yaml cleans pkg/api and docs/openapi first)
cmd="buf generate"

echo "Running '$cmd'"
$cmd

status=$?

if [ "$status" != 0 ]
then
	echo "Error: $cmd failed"
	exit 1
fi

# Set API metadata and security scheme on every generated OpenAPI document;
# the API version is derived from the folder name (v2 -> 2.0.0)
for spec in docs/openapi/v[0-9]*/index.openapi.json
do
	version="$(basename "$(dirname "$spec")" | sed 's/^v//').0.0"

	jq --arg version "$version" '
		.info = {
			title: "Zonyx Alerts API",
			version: $version,
			description: "Ingestion of indoor-location and tag-info events, tag registration, alert rule management, and alert history.",
			contact: {
				name: "Zonyx",
				url: "https://github.com/ZonyxNagi/proto-zonyx-alerts",
				email: "develop@nagi.es"
			}
		}
		| .components.securitySchemes = {
			bearer: {
				type: "http",
				scheme: "bearer",
				description: "Bearer token sent in the \"Authorization\" header."
			}
		}
		| .security = [{bearer: []}]
	' "$spec" >| "$spec.tmp" && mv "$spec.tmp" "$spec"

	status=$?

	if [ "$status" != 0 ]
	then
		echo "Error: post-processing $spec failed"
		exit 1
	fi
done

# Generate versions.txt
ls docs/openapi | grep "^v[0-9]" >| docs/openapi/versions.txt
