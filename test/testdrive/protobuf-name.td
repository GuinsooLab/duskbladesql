# Copyright Materialize, Inc. and contributors. All rights reserved.
#
# Use of this software is governed by the Business Source License
# included in the LICENSE file at the root of this repository.
#
# As of the Change Date specified in that file, in accordance with
# the Business Source License, use of this software will be governed
# by the Apache License, Version 2.0.

# Test the various ways to specify the path to a Protobuf message.

$ file-append path=name.proto
syntax = "proto3";

package some.where;

message Name {
    int32 i = 1;
}

$ protobuf-compile-descriptors inputs=name.proto output=name.pb

$ kafka-create-topic topic=name partitions=1

$ kafka-ingest topic=name format=protobuf descriptor-file=name.pb message=some.where.Name
{"i": 42}

# Ingesting with the fully-qualified absolute path should work.
> CREATE MATERIALIZED SOURCE qualified_absolute_path FROM
  KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'testdrive-name-${testdrive.seed}'
  FORMAT PROTOBUF MESSAGE '.some.where.Name' USING SCHEMA FILE '${testdrive.temp-dir}/name.pb'
> SELECT i, mz_offset FROM qualified_absolute_path
i   mz_offset
-------------
42  1

# Ingesting with the absolute path should work without the leading dot.
> CREATE MATERIALIZED SOURCE absolute_path FROM
  KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'testdrive-name-${testdrive.seed}'
  FORMAT PROTOBUF MESSAGE 'some.where.Name' USING SCHEMA FILE '${testdrive.temp-dir}/name.pb'
> SELECT i, mz_offset FROM absolute_path
i   mz_offset
-------------
42  1

# Ingesting without the package prefix should fail.
! CREATE MATERIALIZED SOURCE absolute_path FROM
  KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'testdrive-name-${testdrive.seed}'
  FORMAT PROTOBUF MESSAGE 'Name' USING SCHEMA FILE '${testdrive.temp-dir}/name.pb'
contains:protobuf message "Name" not found in file descriptor set
! CREATE MATERIALIZED SOURCE absolute_path FROM
  KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'testdrive-name-${testdrive.seed}'
  FORMAT PROTOBUF MESSAGE '.Name' USING SCHEMA FILE '${testdrive.temp-dir}/name.pb'
contains:protobuf message ".Name" not found in file descriptor set
