// Copyright Materialize, Inc. and contributors. All rights reserved.
//
// Use of this software is governed by the Business Source License
// included in the LICENSE file.
//
// As of the Change Date specified in that file, in accordance with
// the Business Source License, use of this software will be governed
// by the Apache License, Version 2.0.

//! Connection types.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::str::FromStr;

use anyhow::{anyhow, bail};
use proptest::prelude::{any, Arbitrary, BoxedStrategy, Strategy};
use proptest_derive::Arbitrary;
use serde::{Deserialize, Serialize};
use url::Url;

use mz_ccsr::tls::{Certificate, Identity};
use mz_kafka_util::KafkaAddrs;
use mz_proto::{IntoRustIfSome, ProtoType, RustType, TryFromProtoError};
use mz_repr::url::any_url;
use mz_repr::GlobalId;
use mz_secrets::{SecretsReader, SecretsReaderConfig};
use mz_sql_parser::ast::KafkaConnectionOptionName;

use crate::types::connections::aws::AwsExternalIdPrefix;

pub mod aws;

include!(concat!(
    env!("OUT_DIR"),
    "/mz_dataflow_types.types.connections.rs"
));

#[derive(Arbitrary, Clone, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub enum StringOrSecret {
    String(String),
    Secret(GlobalId),
}

impl StringOrSecret {
    /// Gets the value as a string, reading the secret if necessary.
    pub async fn get_string(&self, secrets_reader: &SecretsReader) -> anyhow::Result<String> {
        match self {
            StringOrSecret::String(s) => Ok(s.clone()),
            StringOrSecret::Secret(id) => secrets_reader.read_string(*id).await,
        }
    }

    /// Asserts that this string or secret is a string and returns its contents.
    pub fn unwrap_string(&self) -> &str {
        match self {
            StringOrSecret::String(s) => s,
            StringOrSecret::Secret(_) => panic!("StringOrSecret::unwrap_string called on a secret"),
        }
    }

    /// Asserts that this string or secret is a secret and returns its global
    /// ID.
    pub fn unwrap_secret(&self) -> GlobalId {
        match self {
            StringOrSecret::String(_) => panic!("StringOrSecret::unwrap_secret called on a string"),
            StringOrSecret::Secret(id) => *id,
        }
    }
}

impl RustType<ProtoStringOrSecret> for StringOrSecret {
    fn into_proto(&self) -> ProtoStringOrSecret {
        use proto_string_or_secret::Kind;
        ProtoStringOrSecret {
            kind: Some(match self {
                StringOrSecret::String(s) => Kind::String(s.clone()),
                StringOrSecret::Secret(id) => Kind::Secret(id.into_proto()),
            }),
        }
    }

    fn from_proto(proto: ProtoStringOrSecret) -> Result<Self, TryFromProtoError> {
        use proto_string_or_secret::Kind;
        let kind = proto
            .kind
            .ok_or_else(|| TryFromProtoError::missing_field("ProtoStringOrSecret::kind"))?;
        Ok(match kind {
            Kind::String(s) => StringOrSecret::String(s),
            Kind::Secret(id) => StringOrSecret::Secret(GlobalId::from_proto(id)?),
        })
    }
}

impl<V: std::fmt::Display> From<V> for StringOrSecret {
    fn from(v: V) -> StringOrSecret {
        StringOrSecret::String(format!("{}", v))
    }
}

/// Extra context to pass through when instantiating a connection for a source
/// or sink.
///
/// Should be kept cheaply cloneable.
#[derive(Debug, Clone)]
pub struct ConnectionContext {
    /// The level for librdkafka's logs.
    pub librdkafka_log_level: tracing::Level,
    /// A prefix for an external ID to use for all AWS AssumeRole operations.
    pub aws_external_id_prefix: Option<AwsExternalIdPrefix>,
    /// A secrets reader.
    pub secrets_reader: SecretsReader,
}

impl ConnectionContext {
    /// Constructs a new connection context from command line arguments.
    ///
    /// **WARNING:** it is critical for security that the `aws_external_id` be
    /// provided by the operator of the Materialize service (i.e., via a CLI
    /// argument or environment variable) and not the end user of Materialize
    /// (e.g., via a configuration option in a SQL statement). See
    /// [`AwsExternalIdPrefix`] for details.
    pub fn from_cli_args(
        filter: &tracing_subscriber::filter::Targets,
        aws_external_id_prefix: Option<String>,
        secrets_path: PathBuf,
    ) -> ConnectionContext {
        ConnectionContext {
            librdkafka_log_level: mz_ore::tracing::target_level(filter, "librdkafka"),
            aws_external_id_prefix: aws_external_id_prefix.map(AwsExternalIdPrefix),
            secrets_reader: SecretsReader::new(SecretsReaderConfig {
                mount_path: secrets_path,
            }),
        }
    }
}

impl Default for ConnectionContext {
    fn default() -> ConnectionContext {
        ConnectionContext {
            librdkafka_log_level: tracing::Level::INFO,
            aws_external_id_prefix: None,
            secrets_reader: SecretsReader::new(SecretsReaderConfig {
                // NOTE(benesch): this will vanish in a future secrets PR.
                mount_path: "/dev/null".into(),
            }),
        }
    }
}

#[derive(Arbitrary, Clone, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub enum Connection {
    Kafka(KafkaConnection),
    Csr(CsrConnection),
}

#[derive(Arbitrary, Clone, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub struct SslConfig {
    pub key: GlobalId,
    pub key_password: GlobalId,
    pub certificate: StringOrSecret,
    pub certificate_authority: StringOrSecret,
}

#[derive(Arbitrary, Clone, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub struct SaslConfig {
    pub mechanisms: String,
    pub username: StringOrSecret,
    pub password: GlobalId,
    pub certificate_authority: StringOrSecret,
}

#[derive(Arbitrary, Clone, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub enum Security {
    Ssl(SslConfig),
    Sasl(SaslConfig),
}

impl From<SslConfig> for Security {
    fn from(c: SslConfig) -> Self {
        Security::Ssl(c)
    }
}

impl From<SaslConfig> for Security {
    fn from(c: SaslConfig) -> Self {
        Security::Sasl(c)
    }
}

/// Meant to create an equivalence function between enum-named options and
/// their free-form `String` counterparts.
pub trait ConfigKey {
    fn config_key(&self) -> String;
}

impl ConfigKey for KafkaConnectionOptionName {
    fn config_key(&self) -> String {
        use KafkaConnectionOptionName::*;
        match self {
            Broker | Brokers => "bootstrap.servers",
            SslKey => "ssl.key.pem",
            SslKeyPassword => "ssl.key.password",
            SslCertificate => "ssl.certificate.pem",
            SslCertificateAuthority => "ssl.ca.pem",
            SaslMechanisms => "sasl.mechanisms",
            SaslUsername => "sasl.username",
            SaslPassword => "sasl.password",
        }
        .to_string()
    }
}

#[derive(Arbitrary, Clone, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub struct KafkaConnection {
    pub brokers: Vec<String>,
    pub security: Option<Security>,
}

impl From<KafkaConnection> for BTreeMap<String, StringOrSecret> {
    fn from(v: KafkaConnection) -> Self {
        use KafkaConnectionOptionName::*;
        let mut r = BTreeMap::new();
        r.insert("bootstrap.servers".into(), v.brokers.join(",").into());
        match v.security {
            Some(Security::Ssl(SslConfig {
                key,
                key_password,
                certificate,
                certificate_authority,
            })) => {
                r.insert("security.protocol".into(), "SSL".into());
                r.insert(SslKey.config_key(), StringOrSecret::Secret(key));
                r.insert(
                    SslKeyPassword.config_key(),
                    StringOrSecret::Secret(key_password),
                );
                r.insert(SslCertificate.config_key(), certificate);
                r.insert(SslCertificateAuthority.config_key(), certificate_authority);
            }
            Some(Security::Sasl(SaslConfig {
                mechanisms,
                username,
                password,
                certificate_authority,
            })) => {
                r.insert("security.protocol".into(), "SASL_SSL".into());
                r.insert(
                    SaslMechanisms.config_key(),
                    StringOrSecret::String(mechanisms),
                );
                r.insert(SaslUsername.config_key(), username);
                r.insert(SaslPassword.config_key(), StringOrSecret::Secret(password));
                r.insert(SslCertificateAuthority.config_key(), certificate_authority);
            }
            None => {}
        }

        r
    }
}

impl TryFrom<&mut BTreeMap<String, StringOrSecret>> for KafkaConnection {
    type Error = anyhow::Error;
    /// Extracts only the options necessary to create a `KafkaConnection` from
    /// a `BTreeMap<String, StringOrSecret>`, and returns the remaining
    /// options.
    ///
    /// # Panics
    /// - If `value` was not sufficiently or incorrectly type checked and
    ///   parameters expected to reference objects (i.e. secrets) are instead
    ///   `String`s, or vice versa.
    fn try_from(map: &mut BTreeMap<String, StringOrSecret>) -> Result<Self, Self::Error> {
        use KafkaConnectionOptionName::*;

        let key_or_err = |config: &str,
                          map: &mut BTreeMap<String, StringOrSecret>,
                          key: KafkaConnectionOptionName| {
            map.remove(&key.config_key()).ok_or_else(|| {
                anyhow!(
                    "invalid {} config: missing {} ({})",
                    config.to_uppercase(),
                    key,
                    key.config_key(),
                )
            })
        };

        let security = if let Some(v) = map.remove("security.protocol") {
            match v.unwrap_string().to_lowercase().as_str() {
                config @ "ssl" => Some(Security::Ssl(SslConfig {
                    key: key_or_err(config, map, SslKey)?.unwrap_secret(),
                    key_password: key_or_err(config, map, SslKeyPassword)?.unwrap_secret(),
                    certificate: key_or_err(config, map, SslCertificate)?,
                    certificate_authority: key_or_err(config, map, SslCertificateAuthority)?,
                })),
                config @ "sasl_ssl" => Some(Security::Sasl(SaslConfig {
                    mechanisms: key_or_err(config, map, SaslMechanisms)?
                        .unwrap_string()
                        .to_string(),
                    username: key_or_err(config, map, SaslUsername)?,
                    password: key_or_err(config, map, SaslPassword)?.unwrap_secret(),
                    certificate_authority: key_or_err(config, map, SslCertificateAuthority)?,
                })),
                o => bail!("unsupported security.protocol: {}", o),
            }
        } else {
            None
        };

        let brokers = match map.remove(&Broker.config_key()) {
            Some(v) => KafkaAddrs::from_str(&v.unwrap_string())?
                .to_string()
                .split(',')
                .map(|s| s.to_string())
                .collect::<Vec<_>>(),
            None => bail!("must specify {}", Broker.config_key()),
        };

        Ok(KafkaConnection { brokers, security })
    }
}

impl RustType<ProtoKafkaConnectionSslConfig> for SslConfig {
    fn into_proto(&self) -> ProtoKafkaConnectionSslConfig {
        ProtoKafkaConnectionSslConfig {
            key: Some(self.key.into_proto()),
            key_password: Some(self.key_password.into_proto()),
            certificate: Some(self.certificate.into_proto()),
            certificate_authority: Some(self.certificate_authority.into_proto()),
        }
    }

    fn from_proto(proto: ProtoKafkaConnectionSslConfig) -> Result<Self, TryFromProtoError> {
        Ok(SslConfig {
            key: proto
                .key
                .into_rust_if_some("ProtoKafkaConnectionSslConfig::key")?,
            key_password: proto
                .key_password
                .into_rust_if_some("ProtoKafkaConnectionSslConfig::key_password")?,
            certificate: proto
                .certificate
                .into_rust_if_some("ProtoKafkaConnectionSslConfig::certificate")?,
            certificate_authority: proto
                .certificate_authority
                .into_rust_if_some("ProtoKafkaConnectionSslConfig::certificate_authority")?,
        })
    }
}

impl RustType<ProtoKafkaConnectionSaslConfig> for SaslConfig {
    fn into_proto(&self) -> ProtoKafkaConnectionSaslConfig {
        ProtoKafkaConnectionSaslConfig {
            mechanisms: self.mechanisms.into_proto(),
            username: Some(self.username.into_proto()),
            password: Some(self.password.into_proto()),
            certificate_authority: Some(self.certificate_authority.into_proto()),
        }
    }

    fn from_proto(proto: ProtoKafkaConnectionSaslConfig) -> Result<Self, TryFromProtoError> {
        Ok(SaslConfig {
            mechanisms: proto.mechanisms,
            username: proto
                .username
                .into_rust_if_some("ProtoKafkaConnectionSaslConfig::username")?,
            password: proto
                .password
                .into_rust_if_some("ProtoKafkaConnectionSaslConfig::password")?,
            certificate_authority: proto
                .certificate_authority
                .into_rust_if_some("ProtoKafkaConnectionSaslConfig::certificate_authority")?,
        })
    }
}

impl RustType<ProtoKafkaConnectionSecurity> for Security {
    fn into_proto(&self) -> ProtoKafkaConnectionSecurity {
        use proto_kafka_connection_security::Kind;
        ProtoKafkaConnectionSecurity {
            kind: Some(match self {
                Security::Ssl(config) => Kind::Ssl(config.into_proto()),
                Security::Sasl(config) => Kind::Sasl(config.into_proto()),
            }),
        }
    }

    fn from_proto(proto: ProtoKafkaConnectionSecurity) -> Result<Self, TryFromProtoError> {
        use proto_kafka_connection_security::Kind;
        let kind = proto.kind.ok_or_else(|| {
            TryFromProtoError::missing_field("ProtoKafkaConnectionSecurity::kind")
        })?;
        Ok(match kind {
            Kind::Ssl(s) => Security::Ssl(SslConfig::from_proto(s)?),
            Kind::Sasl(s) => Security::Sasl(SaslConfig::from_proto(s)?),
        })
    }
}

impl RustType<ProtoKafkaConnection> for KafkaConnection {
    fn into_proto(&self) -> ProtoKafkaConnection {
        ProtoKafkaConnection {
            brokers: self.brokers.into_proto(),
            security: self.security.into_proto(),
        }
    }

    fn from_proto(proto: ProtoKafkaConnection) -> Result<Self, TryFromProtoError> {
        Ok(KafkaConnection {
            brokers: proto.brokers,
            security: proto.security.into_rust()?,
        })
    }
}

/// A connection to a Confluent Schema Registry.
#[derive(Clone, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub struct CsrConnection {
    /// The URL of the schema registry.
    pub url: Url,
    /// Trusted root TLS certificates in PEM format.
    pub root_certs: Vec<StringOrSecret>,
    /// An optional TLS client certificate for authentication with the schema
    /// registry.
    pub tls_identity: Option<CsrConnectionTlsIdentity>,
    /// Optional HTTP authentication credentials for the schema registry.
    pub http_auth: Option<CsrConnectionHttpAuth>,
}

impl CsrConnection {
    /// Constructs a schema registry client from the connection.
    pub async fn connect(
        &self,
        secrets_reader: &SecretsReader,
    ) -> Result<mz_ccsr::Client, anyhow::Error> {
        let mut client_config = mz_ccsr::ClientConfig::new(self.url.clone());
        for root_cert in &self.root_certs {
            let root_cert = root_cert.get_string(secrets_reader).await?;
            let root_cert = Certificate::from_pem(&root_cert.as_bytes())?;
            client_config = client_config.add_root_certificate(root_cert);
        }

        if let Some(tls_identity) = &self.tls_identity {
            let key = secrets_reader.read_string(tls_identity.key).await?;
            let cert = tls_identity.cert.get_string(secrets_reader).await?;
            // `reqwest` expects identity `pem` files to contain one key and
            // at least one certificate.
            let mut buf = Vec::new();
            buf.extend(key.as_bytes());
            buf.push(b'\n');
            buf.extend(cert.as_bytes());
            let ident = Identity::from_pem(&buf)?;
            client_config = client_config.identity(ident);
        }

        if let Some(http_auth) = &self.http_auth {
            let username = http_auth.username.get_string(secrets_reader).await?;
            let password = match http_auth.password {
                None => None,
                Some(password) => Some(secrets_reader.read_string(password).await?),
            };
            client_config = client_config.auth(username, password);
        }

        client_config.build()
    }
}

impl RustType<ProtoCsrConnection> for CsrConnection {
    fn into_proto(&self) -> ProtoCsrConnection {
        ProtoCsrConnection {
            url: Some(self.url.into_proto()),
            root_certs: self.root_certs.into_proto(),
            tls_identity: self.tls_identity.into_proto(),
            http_auth: self.http_auth.into_proto(),
        }
    }

    fn from_proto(proto: ProtoCsrConnection) -> Result<Self, TryFromProtoError> {
        Ok(CsrConnection {
            url: proto.url.into_rust_if_some("ProtoCsrConnection::url")?,
            root_certs: proto.root_certs.into_rust()?,
            tls_identity: proto.tls_identity.into_rust()?,
            http_auth: proto.http_auth.into_rust()?,
        })
    }
}

impl Arbitrary for CsrConnection {
    type Strategy = BoxedStrategy<Self>;
    type Parameters = ();

    fn arbitrary_with(_: Self::Parameters) -> Self::Strategy {
        (
            any_url(),
            any::<Vec<StringOrSecret>>(),
            any::<Option<CsrConnectionTlsIdentity>>(),
            any::<Option<CsrConnectionHttpAuth>>(),
        )
            .prop_map(|(url, root_certs, tls_identity, http_auth)| CsrConnection {
                url,
                root_certs,
                tls_identity,
                http_auth,
            })
            .boxed()
    }
}

/// A TLS key pair in a [`CsrConnection`].
#[derive(Arbitrary, Clone, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub struct CsrConnectionTlsIdentity {
    /// The client's TLS public certificate in PEM format.
    pub cert: StringOrSecret,
    /// The ID of the secret containing the client's TLS private key in PEM
    /// format.
    pub key: GlobalId,
}

impl RustType<ProtoCsrConnectionTlsIdentity> for CsrConnectionTlsIdentity {
    fn into_proto(&self) -> ProtoCsrConnectionTlsIdentity {
        ProtoCsrConnectionTlsIdentity {
            cert: Some(self.cert.into_proto()),
            key: Some(self.key.into_proto()),
        }
    }

    fn from_proto(proto: ProtoCsrConnectionTlsIdentity) -> Result<Self, TryFromProtoError> {
        Ok(CsrConnectionTlsIdentity {
            cert: proto
                .cert
                .into_rust_if_some("ProtoCsrConnectionTlsIdentity::cert")?,
            key: proto
                .key
                .into_rust_if_some("ProtoCsrConnectionTlsIdentity::key")?,
        })
    }
}

/// HTTP authentication credentials in a [`CsrConnection`].
#[derive(Arbitrary, Clone, Debug, Eq, PartialEq, Hash, Serialize, Deserialize)]
pub struct CsrConnectionHttpAuth {
    /// The username.
    pub username: StringOrSecret,
    /// The ID of the secret containing the password, if any.
    pub password: Option<GlobalId>,
}

impl RustType<ProtoCsrConnectionHttpAuth> for CsrConnectionHttpAuth {
    fn into_proto(&self) -> ProtoCsrConnectionHttpAuth {
        ProtoCsrConnectionHttpAuth {
            username: Some(self.username.into_proto()),
            password: self.password.into_proto(),
        }
    }

    fn from_proto(proto: ProtoCsrConnectionHttpAuth) -> Result<Self, TryFromProtoError> {
        Ok(CsrConnectionHttpAuth {
            username: proto
                .username
                .into_rust_if_some("ProtoCsrConnectionHttpAuth::username")?,
            password: proto.password.into_rust()?,
        })
    }
}
