# Copyright Materialize, Inc. and contributors. All rights reserved.
#
# Use of this software is governed by the Business Source License
# included in the LICENSE file at the root of this repository.
#
# As of the Change Date specified in that file, in accordance with
# the Business Source License, use of this software will be governed
# by the Apache License, Version 2.0.

# Test Avro UPSERT sinks.

# sinking directly from an UPSERT source with multi-part key

$ set upsert-keyschema={
    "type": "record",
    "name": "Key",
    "fields": [
        {"name": "key1", "type": "string"},
        {"name": "key2", "type": "long"}
    ]
  }

$ set upsert-schema={
        "type" : "record",
        "name" : "test",
        "fields" : [
            {"name":"f1", "type":"string"},
            {"name":"f2", "type":"long"}
        ]
    }

$ kafka-create-topic topic=upsert-avro

$ kafka-ingest format=avro topic=upsert-avro key-format=avro key-schema=${upsert-keyschema} schema=${upsert-schema} publish=true
{"key1": "fish", "key2": 2} {"f1": "fish", "f2": 1000}
{"key1": "fisch", "key2": 42} {"f1": "fish", "f2": 1000}

> CREATE MATERIALIZED SOURCE upsert_input
  FROM KAFKA BROKER '${testdrive.kafka-addr}' TOPIC
  'testdrive-upsert-avro-${testdrive.seed}'
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY '${testdrive.schema-registry-url}'
  ENVELOPE UPSERT

> CREATE SINK upsert_input_sink FROM upsert_input
  INTO KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'upsert-input-sink'
  KEY (key1, key2)
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY '${testdrive.schema-registry-url}' ENVELOPE UPSERT

$ kafka-verify format=avro sink=materialize.public.upsert_input_sink sort-messages=true
{"key1": "fisch", "key2": 42} {"key1": "fisch", "key2": 42, "f1": "fish", "f2": 1000}
{"key1": "fish", "key2": 2} {"key1": "fish", "key2": 2, "f1": "fish", "f2": 1000}

$ kafka-ingest format=avro topic=upsert-avro key-format=avro key-schema=${upsert-keyschema} schema=${upsert-schema} publish=true
{"key1": "fisch", "key2": 42} {"f1": "richtig, fisch", "f2": 2000}

$ kafka-verify format=avro sink=materialize.public.upsert_input_sink
{"key1": "fisch", "key2": 42} {"key1": "fisch", "key2": 42, "f1": "richtig, fisch", "f2": 2000}

# More complicated scenarios: super keys, consistency input/output
$ set schema=[
  {
    "type": "array",
    "items": {
      "type": "record",
      "name": "update",
      "namespace": "com.materialize.cdc",
      "fields": [
        {
          "name": "data",
          "type": {
            "type": "record",
            "name": "data",
            "fields": [
              {"name": "a", "type": "long"},
              {"name": "b", "type": "long"}
            ]
          }
        },
        {
          "name": "time",
          "type": "long"
        },
        {
          "name": "diff",
          "type": "long"
        }
      ]
    }
  },
  {
    "type": "record",
    "name": "progress",
    "namespace": "com.materialize.cdc",
    "fields": [
      {
        "name": "lower",
        "type": {
          "type": "array",
          "items": "long"
        }
      },
      {
        "name": "upper",
        "type": {
          "type": "array",
          "items": "long"
        }
      },
      {
        "name": "counts",
        "type": {
          "type": "array",
          "items": {
            "type": "record",
            "name": "counts",
            "fields": [
              {
                "name": "time",
                "type": "long"
              },
              {
                "name": "count",
                "type": "long"
              }
            ]
          }
        }
      }
    ]
  }
  ]

$ kafka-create-topic topic=input

# (PRIMARY KEY (id) NOT ENFORCED)
> CREATE MATERIALIZED SOURCE input
  FROM KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'testdrive-input-${testdrive.seed}'
  FORMAT AVRO USING SCHEMA '${schema}' ENVELOPE MATERIALIZE

> CREATE VIEW input_keyed AS SELECT a, max(b) as b FROM input GROUP BY a

> CREATE SINK input_sink FROM input_keyed
  INTO KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'input-sink' KEY (a)
  WITH (consistency_topic = 'input-sink-consistency') FORMAT AVRO
  USING CONFLUENT SCHEMA REGISTRY '${testdrive.schema-registry-url}' ENVELOPE UPSERT

# requesting to key by (a, b) is fine when (a) is a unique key

> CREATE SINK input_sink_multiple_keys FROM input_keyed
  INTO KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'input-sink' KEY (b, a)
  WITH (consistency_topic = 'input-sink-consistency') FORMAT AVRO
  USING CONFLUENT SCHEMA REGISTRY '${testdrive.schema-registry-url}' ENVELOPE UPSERT

$ kafka-ingest format=avro topic=input schema=${schema}
{"array":[{"data":{"a":1,"b":1},"time":1,"diff":1}]}
{"array":[{"data":{"a":2,"b":2},"time":1,"diff":1}]}
{"array":[{"data":{"a":3,"b":1},"time":2,"diff":1}]}
{"array":[{"data":{"a":4,"b":2},"time":2,"diff":1}]}
{"array":[{"data":{"a":1,"b":7},"time":3,"diff":1}]}
{"com.materialize.cdc.progress":{"lower":[0],"upper":[4],"counts":[{"time":1,"count":2},{"time":2,"count":2}, {"time": 3, "count": 1}]}}

> SELECT * FROM input;
a  b
------
1  1
2  2
3  1
4  2
1  7

# Compare sorted messages within each transaction. We know that messages of one
# transaction appear together as one "bundle" in the output. But there is no
# guarantee on the order within a transaction.

$ kafka-verify format=avro sink=materialize.public.input_sink sort-messages=true
{"a": 1} {"a": 1, "b": 1, "transaction": {"id": "1"}}
{"a": 2} {"a": 2, "b": 2, "transaction": {"id": "1"}}

$ kafka-verify format=avro sink=materialize.public.input_sink sort-messages=true
{"a": 3} {"a": 3, "b": 1, "transaction": {"id": "2"}}
{"a": 4} {"a": 4, "b": 2, "transaction": {"id": "2"}}

$ kafka-verify format=avro sink=materialize.public.input_sink sort-messages=true
{"a": 1} {"a": 1, "b": 7, "transaction": {"id": "3"}}

$ kafka-verify format=avro sink=materialize.public.input_sink consistency=debezium
{"status":"BEGIN","id":"1","event_count":null,"data_collections":null}
{"status":"END","id":"1","event_count":{"long": 2},"data_collections":{"array": [{"event_count": 2, "data_collection": "input-sink"}]}}
{"status":"BEGIN","id":"2","event_count":null,"data_collections":null}
{"status":"END","id":"2","event_count":{"long": 2},"data_collections":{"array": [{"event_count": 2, "data_collection": "input-sink"}]}}
{"status":"BEGIN","id":"3","event_count":null,"data_collections":null}
{"status":"END","id":"3","event_count":{"long": 1},"data_collections":{"array": [{"event_count": 1, "data_collection": "input-sink"}]}}

# Again, compare split by transaction. See comment just above.

$ kafka-verify format=avro sink=materialize.public.input_sink_multiple_keys sort-messages=true
{"a": 1, "b": 1} {"a": 1, "b": 1, "transaction": {"id": "1"}}
{"a": 2, "b": 2} {"a": 2, "b": 2, "transaction": {"id": "1"}}

$ kafka-verify format=avro sink=materialize.public.input_sink_multiple_keys sort-messages=true
{"a": 3, "b": 1} {"a": 3, "b": 1, "transaction": {"id": "2"}}
{"a": 4, "b": 2} {"a": 4, "b": 2, "transaction": {"id": "2"}}

# missing key denotes DELETE

$ kafka-verify format=avro sink=materialize.public.input_sink_multiple_keys sort-messages=true
{"a": 1, "b": 1}
{"a": 1, "b": 7} {"a": 1, "b": 7, "transaction": {"id": "3"}}

# verify if/when input deletions are emitted to an UPSERT sink

$ kafka-create-topic topic=input-with-deletions

> CREATE MATERIALIZED SOURCE input_with_deletions
  FROM KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'testdrive-input-with-deletions-${testdrive.seed}'
  FORMAT AVRO USING SCHEMA '${schema}' ENVELOPE MATERIALIZE

> CREATE VIEW input_with_deletions_keyed AS SELECT a, max(b) as b FROM input_with_deletions GROUP BY a

> CREATE SINK input_with_deletions_sink FROM input_with_deletions_keyed
  INTO KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'input-sink' KEY (a)
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY '${testdrive.schema-registry-url}' ENVELOPE UPSERT

$ kafka-ingest format=avro topic=input-with-deletions schema=${schema}
{"array":[{"data":{"a":1,"b":1},"time":1,"diff":1}]}
{"com.materialize.cdc.progress":{"lower":[0],"upper":[2],"counts":[{"time":1,"count":1}]}}

$ kafka-verify format=avro sink=materialize.public.input_with_deletions_sink sort-messages=true
{"a": 1} {"a": 1, "b": 1}

$ kafka-ingest format=avro topic=input-with-deletions schema=${schema}
{"array":[{"data":{"a":1,"b":2},"time":2,"diff":1}]}
{"com.materialize.cdc.progress":{"lower":[2],"upper":[3],"counts":[{"time":2,"count":1}]}}

$ kafka-verify format=avro sink=materialize.public.input_with_deletions_sink sort-messages=true
{"a": 1} {"a": 1, "b": 2}

# deletion of the "shadowed" input should not cause downstream updates

$ kafka-ingest format=avro topic=input-with-deletions schema=${schema}
{"array":[{"data":{"a":1,"b":1},"time":3,"diff":-1}]}
{"com.materialize.cdc.progress":{"lower":[3],"upper":[4],"counts":[{"time":3,"count":1}]}}

$ kafka-ingest format=avro topic=input-with-deletions schema=${schema}
{"array":[{"data":{"a":1,"b":2},"time":4,"diff":-1}]}
{"com.materialize.cdc.progress":{"lower":[4],"upper":[5],"counts":[{"time":4,"count":1}]}}

# now we should see a NULL update on the key, which means a DELETE

$ kafka-verify format=avro sink=materialize.public.input_with_deletions_sink sort-messages=true
{"a": 1}

$ kafka-ingest format=avro topic=input-with-deletions schema=${schema}
{"array":[{"data":{"a":1,"b":1},"time":5,"diff":1}]}
{"array":[{"data":{"a":1,"b":2},"time":5,"diff":1}]}
{"com.materialize.cdc.progress":{"lower":[5],"upper":[6],"counts":[{"time":5,"count":2}]}}

$ kafka-verify format=avro sink=materialize.public.input_with_deletions_sink sort-messages=true
{"a": 1} {"a": 1, "b": 2}

$ kafka-ingest format=avro topic=input-with-deletions schema=${schema}
{"array":[{"data":{"a":1,"b":2},"time":6,"diff":-1}]}
{"com.materialize.cdc.progress":{"lower":[6],"upper":[7],"counts":[{"time":6,"count":1}]}}

# removing the occluding input should "reveal" the previous input again
#
$ kafka-verify format=avro sink=materialize.public.input_with_deletions_sink sort-messages=true
{"a": 1} {"a": 1, "b": 1}

# NOT ENFORCED Keys

$ kafka-create-topic topic=non-keyed-input

> CREATE MATERIALIZED SOURCE non_keyed_input
  FROM KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'testdrive-non-keyed-input-${testdrive.seed}'
  FORMAT AVRO USING SCHEMA '${schema}' ENVELOPE MATERIALIZE

> CREATE SINK not_enforced_key FROM non_keyed_input
  INTO KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'not-enforced-sink' KEY (a) NOT ENFORCED
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY '${testdrive.schema-registry-url}' ENVELOPE UPSERT

# Bad upsert keys

! CREATE SINK invalid_key FROM input
  INTO KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'input-sink' KEY (a)
  WITH (consistency_topic = true) FORMAT AVRO
  USING CONFLUENT SCHEMA REGISTRY '${testdrive.schema-registry-url}' ENVELOPE UPSERT
contains:Invalid upsert key: (a), there are no valid keys

! CREATE SINK another_invalid_key FROM input_keyed
  INTO KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'input-sink' KEY (b)
  WITH (consistency_topic = true) FORMAT AVRO
  USING CONFLUENT SCHEMA REGISTRY '${testdrive.schema-registry-url}' ENVELOPE UPSERT
contains:Invalid upsert key: (b), valid keys are: (a)

> CREATE VIEW input_keyed_ab AS SELECT a, b FROM input GROUP BY a, b

! CREATE SINK invalid_sub_key FROM input_keyed_ab
  INTO KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'input-sink' KEY (a)
  WITH (consistency_topic = true) FORMAT AVRO
  USING CONFLUENT SCHEMA REGISTRY '${testdrive.schema-registry-url}' ENVELOPE UPSERT
contains:Invalid upsert key: (a), valid keys are: (a, b)

! CREATE SINK another_invalid_sub_key FROM input_keyed_ab
  INTO KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'input-sink' KEY (b)
  WITH (consistency_topic = true) FORMAT AVRO
  USING CONFLUENT SCHEMA REGISTRY '${testdrive.schema-registry-url}' ENVELOPE UPSERT
contains:Invalid upsert key: (b), valid keys are: (a, b)

! CREATE SINK invalid_key_from_upsert_input FROM upsert_input
  INTO KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'data-sink'
  KEY (key1)
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY '${testdrive.schema-registry-url}' ENVELOPE UPSERT
contains:Invalid upsert key: (key1), valid keys are: (key1, key2)

! CREATE SINK invalid_key_from_upsert_input FROM upsert_input
  INTO KAFKA BROKER '${testdrive.kafka-addr}' TOPIC 'data-sink'
  KEY (key2)
  FORMAT AVRO USING CONFLUENT SCHEMA REGISTRY '${testdrive.schema-registry-url}' ENVELOPE UPSERT
contains:Invalid upsert key: (key2), valid keys are: (key1, key2)
