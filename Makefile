ENV ?= dev # <- Set default env (e.g. prod, dev)

ENV_FILE = .env.$(ENV)
COMPOSE_FILES = -f docker-compose.yml \
  -f services/graylog.yml \
  -f services/grafana.yml \
  -f services/prometheus.yml

COMPOSE = docker compose --env-file $(ENV_FILE) $(COMPOSE_FILES)

up:
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

restart:
	$(COMPOSE) restart

ps:
	$(COMPOSE) ps

logs:
	$(COMPOSE) logs -f

pull:
	$(COMPOSE) pull --ignore-buildable

build:
	$(COMPOSE) build

deploy:
	@scripts/deploy.sh

install-cron:
	sudo cp configs/cron/tasco-logserver /etc/cron.d/tasco-logserver
	sudo chown root:root /etc/cron.d/tasco-logserver
	sudo chmod 644 /etc/cron.d/tasco-logserver
	sudo systemctl restart cron
	@echo "Cron installed from configs/cron/tasco-logserver"

restart-grafana:
	$(COMPOSE) restart grafana
