terraform {
  required_providers {
    confluent = {
      source  = "confluentinc/confluent"
      version = "1.38.0"
    }
  }
}

## Create a Cloud API Key
#Open the Confluent Cloud Console and click Granular access tab, and then click Next.
#Click Create a new one to create tab. Enter the new service account name (tf_runner), then click Next.
#The Cloud API key and secret are generated for the tf_runner service account. Save your Cloud API key and secret in a secure location. You will need this API key and secret to use the Confluent Terraform Provider.
#Assign the OrganizationAdmin role to the tf_runner service account by following this guide.
provider "confluent" {
  cloud_api_key    = "ZJI5JGJDLQFAQBAY" ##var.confluent_cloud_api_key
  cloud_api_secret = "6wjJZ11weQv8J/LYp3qxfvOI6gSFhf7BSWrqfSQzhc1JrbYsSGQbGf+cvnKljB2w" ##var.confluent_cloud_api_secret
}

data "confluent_environment" "test" {
  id = "${var.CONFLUENT_CLOUD_ENVIRONMENT_ID}"
}

# Stream Governance and Kafka clusters can be in different regions as well as different cloud providers,
# but you should to place both in the same cloud and region to restrict the fault isolation boundary.
#data "confluent_schema_registry_region" "essentials" {
#  cloud   = "AWS"
#  region  = "us-east-2"
#  package = "ESSENTIALS"
#}

#resource "confluent_schema_registry_cluster" "essentials" {
#  package = data.confluent_schema_registry_region.essentials.package
#
#  environment {
#    id = confluent_environment.staging.id
#  }
#
#  region {
#    # See https://docs.confluent.io/cloud/current/stream-governance/packages.html#stream-governance-regions
#    id = data.confluent_schema_registry_region.essentials.id
#  }
#}

# Update the config to use a cloud provider and region of your choice.
# https://registry.terraform.io/providers/confluentinc/confluent/latest/docs/resources/confluent_kafka_cluster
resource "confluent_kafka_cluster" "basic" {
  display_name = "hhan-terraform-test-cluster"
  availability = "SINGLE_ZONE"
  cloud        = "AWS"
  region       = "ap-southeast-1"
  basic {}
  environment {
    id = data.confluent_environment.test.id
  }
}

// 'app-manager' service account is required in this configuration to create 'orders' topic and grant ACLs
// to 'app-producer' and 'app-consumer' service accounts.
resource "confluent_service_account" "hhan-app-manager" {
  display_name = "hhan-app-manager"
  description  = "Service account to manage 'inventory' Kafka cluster"
}

# Bind this Service Account to the CloudClusterAdmin
resource "confluent_role_binding" "hhan-app-manager-kafka-cluster-admin" {
  principal   = "User:${confluent_service_account.hhan-app-manager.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.basic.rbac_crn
}

# CREATE API KEY
resource "confluent_api_key" "hhan-app-manager-kafka-api-key" {
  display_name = "hhan-app-manager-kafka-api-key"
  description  = "Kafka API Key that is owned by 'app-manager' service account"
  owner {
    id          = confluent_service_account.hhan-app-manager.id
    api_version = confluent_service_account.hhan-app-manager.api_version
    kind        = confluent_service_account.hhan-app-manager.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.basic.id
    api_version = confluent_kafka_cluster.basic.api_version
    kind        = confluent_kafka_cluster.basic.kind

    environment {
      id = data.confluent_environment.test.id
    }
  }

  # The goal is to ensure that confluent_role_binding.app-manager-kafka-cluster-admin is created before
  # confluent_api_key.app-manager-kafka-api-key is used to create instances of
  # confluent_kafka_topic, confluent_kafka_acl resources.

  # 'depends_on' meta-argument is specified in confluent_api_key.app-manager-kafka-api-key to avoid having
  # multiple copies of this definition in the configuration which would happen if we specify it in
  # confluent_kafka_topic, confluent_kafka_acl resources instead.
  depends_on = [
    confluent_role_binding.hhan-app-manager-kafka-cluster-admin
  ]
}

#TOPIC
resource "confluent_kafka_topic" "orders" {
  kafka_cluster {
    id = confluent_kafka_cluster.basic.id
  }
  topic_name    = "orders"
  rest_endpoint = confluent_kafka_cluster.basic.rest_endpoint
  config = {
    "cleanup.policy"    = "compact"
    "max.message.bytes" = "12345"
    "retention.ms"      = "67890"
  }
  credentials {
    key    = confluent_api_key.hhan-app-manager-kafka-api-key.id
    secret = confluent_api_key.hhan-app-manager-kafka-api-key.secret
  }
}

resource "confluent_service_account" "hhan-app-consumer" {
  display_name = "hhan-app-consumer"
  description  = "Service account to consume from 'orders' topic of 'inventory' Kafka cluster"
}

resource "confluent_api_key" "hhan-app-consumer-kafka-api-key" {
  display_name = "hhan-app-consumer-kafka-api-key"
  description  = "Kafka API Key that is owned by 'app-consumer' service account"
  owner {
    id          = confluent_service_account.hhan-app-consumer.id
    api_version = confluent_service_account.hhan-app-consumer.api_version
    kind        = confluent_service_account.hhan-app-consumer.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.basic.id
    api_version = confluent_kafka_cluster.basic.api_version
    kind        = confluent_kafka_cluster.basic.kind

    environment {
      id = data.confluent_environment.test.id
    }
  }
}

resource "confluent_kafka_acl" "hhan-app-producer-write-on-topic" {
  kafka_cluster {
    id = confluent_kafka_cluster.basic.id
  }
  resource_type = "TOPIC"
  resource_name = confluent_kafka_topic.orders.topic_name
  pattern_type  = "LITERAL"
  principal     = "User:${confluent_service_account.hhan-app-producer.id}"
  host          = "*"
  operation     = "WRITE"
  permission    = "ALLOW"
  rest_endpoint = confluent_kafka_cluster.basic.rest_endpoint
  credentials {
    key    = confluent_api_key.hhan-app-manager-kafka-api-key.id
    secret = confluent_api_key.hhan-app-manager-kafka-api-key.secret
  }
}

resource "confluent_service_account" "hhan-app-producer" {
  display_name = "hhan-app-producer"
  description  = "Service account to produce to 'orders' topic of 'inventory' Kafka cluster"
}

resource "confluent_api_key" "hhan-app-producer-kafka-api-key" {
  display_name = "hhan-app-producer-kafka-api-key"
  description  = "Kafka API Key that is owned by 'app-producer' service account"
  owner {
    id          = confluent_service_account.hhan-app-producer.id
    api_version = confluent_service_account.hhan-app-producer.api_version
    kind        = confluent_service_account.hhan-app-producer.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.basic.id
    api_version = confluent_kafka_cluster.basic.api_version
    kind        = confluent_kafka_cluster.basic.kind

    environment {
      id = data.confluent_environment.test.id
    }
  }
}

// Note that in order to consume from a topic, the principal of the consumer ('app-consumer' service account)
// needs to be authorized to perform 'READ' operation on both Topic and Group resources:
// confluent_kafka_acl.app-consumer-read-on-topic, confluent_kafka_acl.app-consumer-read-on-group.
// https://docs.confluent.io/platform/current/kafka/authorization.html#using-acls
resource "confluent_kafka_acl" "hhan-app-consumer-read-on-topic" {
  kafka_cluster {
    id = confluent_kafka_cluster.basic.id
  }
  resource_type = "TOPIC"
  resource_name = confluent_kafka_topic.orders.topic_name
  pattern_type  = "LITERAL"
  principal     = "User:${confluent_service_account.hhan-app-consumer.id}"
  host          = "*"
  operation     = "READ"
  permission    = "ALLOW"
  rest_endpoint = confluent_kafka_cluster.basic.rest_endpoint
  credentials {
    key    = confluent_api_key.hhan-app-manager-kafka-api-key.id
    secret = confluent_api_key.hhan-app-manager-kafka-api-key.secret
  }
}

resource "confluent_kafka_acl" "hhan-app-consumer-read-on-group" {
  kafka_cluster {
    id = confluent_kafka_cluster.basic.id
  }
  resource_type = "GROUP"
  // The existing values of resource_name, pattern_type attributes are set up to match Confluent CLI's default consumer group ID ("confluent_cli_consumer_<uuid>").
  // https://docs.confluent.io/confluent-cli/current/command-reference/kafka/topic/confluent_kafka_topic_consume.html
  // Update the values of resource_name, pattern_type attributes to match your target consumer group ID.
  // https://docs.confluent.io/platform/current/kafka/authorization.html#prefixed-acls
  resource_name = "confluent_cli_consumer_"
  pattern_type  = "PREFIXED"
  principal     = "User:${confluent_service_account.hhan-app-consumer.id}"
  host          = "*"
  operation     = "READ"
  permission    = "ALLOW"
  rest_endpoint = confluent_kafka_cluster.basic.rest_endpoint
  credentials {
    key    = confluent_api_key.hhan-app-manager-kafka-api-key.id
    secret = confluent_api_key.hhan-app-manager-kafka-api-key.secret
  }
}