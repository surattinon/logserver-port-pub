ARG OPENSEARCH_VERSION
FROM opensearchproject/opensearch:${OPENSEARCH_VERSION}

ARG OPENSEARCH_PROM_EXPORTER_VERSION
RUN /usr/share/opensearch/bin/opensearch-plugin install --batch \
    "https://github.com/opensearch-project/opensearch-prometheus-exporter/releases/download/${OPENSEARCH_PROM_EXPORTER_VERSION}/prometheus-exporter-${OPENSEARCH_PROM_EXPORTER_VERSION}.zip"
