# Copyright Materialize, Inc. and contributors. All rights reserved.
#
# Use of this software is governed by the Business Source License
# included in the LICENSE file at the root of this repository.
#
# As of the Change Date specified in that file, in accordance with
# the Business Source License, use of this software will be governed
# by the Apache License, Version 2.0.

# Test that Protobuf files with too few or too many messages are handled
# correctly.

$ schema-registry-publish subject=testdrive-too-few-${testdrive.seed}-value schema-type=protobuf
syntax = "proto3";

$ schema-registry-publish subject=testdrive-too-many-${testdrive.seed}-value schema-type=protobuf
syntax = "proto3";

message Message1 {}
message Message2 {}

! CREATE MATERIALIZED SOURCE fail FROM
  KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'testdrive-too-few-${testdrive.seed}'
  FORMAT PROTOBUF USING CONFLUENT SCHEMA REGISTRY '${testdrive.schema-registry-url}'
contains:Protobuf schemas with no messages not yet supported

! CREATE MATERIALIZED SOURCE fail FROM
  KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'testdrive-too-many-${testdrive.seed}'
  FORMAT PROTOBUF USING CONFLUENT SCHEMA REGISTRY '${testdrive.schema-registry-url}'
contains:Protobuf schemas with multiple messages not yet supported
