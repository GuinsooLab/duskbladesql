#!/usr/bin/env bash

# Copyright Materialize, Inc. and contributors. All rights reserved.
#
# Use of this software is governed by the Business Source License
# included in the LICENSE file at the root of this repository.
#
# As of the Change Date specified in that file, in accordance with
# the Business Source License, use of this software will be governed
# by the Apache License, Version 2.0.
#
# test.sh — run .NET language tests.

set -euo pipefail

cd "$(dirname "$0")/../../.."

. misc/shlib/shlib.bash

cd test/lang/csharp

dotnet test csharp-npgsql5.csproj
dotnet test csharp-npgsql6.csproj
