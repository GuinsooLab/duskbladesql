# Copyright Materialize, Inc. and contributors. All rights reserved.
#
# Use of this software is governed by the Business Source License
# included in the LICENSE file at the root of this repository.
#
# As of the Change Date specified in that file, in accordance with
# the Business Source License, use of this software will be governed
# by the Apache License, Version 2.0.

$ schema-registry-wait-schema schema=mysql.test.t1-value

$ mysql-connect name=mysql url=mysql://root@mysql password=${arg.mysql-root-password}

$ mysql-execute name=mysql
USE test;
INSERT INTO t1 VALUES (345, 345);
COMMIT;

$ schema-registry-wait-schema schema=mysql.transaction-value

> CREATE MATERIALIZED SOURCE mysql_tx_metadata
  FROM KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'mysql.transaction'
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY '${testdrive.schema-registry-url}'
  ENVELOPE NONE;

> CREATE MATERIALIZED SOURCE t1
  FROM KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'mysql.test.t1'
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY '${testdrive.schema-registry-url}'
  ENVELOPE DEBEZIUM (
      TRANSACTION METADATA (SOURCE mysql_tx_metadata, COLLECTION 'test.t1')
  );

> SELECT * FROM t1;
123 123
234 234
345 345

$ mysql-execute name=mysql
INSERT INTO t1 VALUES (456, 456);
COMMIT;

> SELECT * FROM t1;
123 123
234 234
345 345
456 456

$ mysql-execute name=mysql
UPDATE t1 SET f2 = f2 * 100
COMMIT;

> SELECT * FROM t1;
123 12300
234 23400
345 34500
456 45600

$ mysql-execute name=mysql
DELETE FROM t1;
COMMIT;

> SELECT COUNT(*) FROM t1;
0
