# JTerrazz Infrastructure Makefile
# Convenient shortcuts for local development and deployment

.DEFAULT_GOAL := help
.PHONY: help local-start local-stop local-clean local-ansible local-kubeconfig local-test local-status local-logs
.PHONY: prod-deploy prod-plan prod-destroy prod-status
.PHONY: setup check deps clean-all

# Colors for output
GREEN := \033[32m
YELLOW := \033[33m
BLUE := \033[34m
RED := \033[31m
NC := \033[0m # No Color

##@ Local Development

local-start: ## 🚀 Start local Docker development environment
	@echo "$(BLUE)Starting local development environment...$(NC)"
	./scripts/local-dev.sh start

local-stop: ## ⏹️  Stop local development environment
	@echo "$(YELLOW)Stopping local development environment...$(NC)"
	./scripts/local-dev.sh stop

local-clean: ## 🧹 Clean local environment (removes all data!)
	@echo "$(RED)Cleaning local development environment...$(NC)"
	./scripts/local-dev.sh clean

local-ansible: ## ⚙️  Run Ansible playbook against local environment
	@echo "$(GREEN)Running Ansible playbook locally...$(NC)"
	./scripts/local-dev.sh ansible

local-ansible-check: ## 🔍 Run Ansible playbook in check mode (dry-run)
	@echo "$(BLUE)Running Ansible dry-run locally...$(NC)"
	./scripts/local-dev.sh ansible --check

local-ansible-tags: ## 🏷️  Run specific Ansible tags (usage: make local-ansible-tags TAGS=k3s,helm)
	@echo "$(GREEN)Running Ansible with tags: $(TAGS)$(NC)"
	./scripts/local-dev.sh ansible --tags $(TAGS)

local-kubeconfig: ## 📋 Get kubeconfig from local k3s cluster
	@echo "$(BLUE)Getting kubeconfig from local k3s...$(NC)"
	./scripts/local-dev.sh get-kubeconfig

local-test: ## ✅ Test local Kubernetes connectivity
	@echo "$(GREEN)Testing local Kubernetes cluster...$(NC)"
	./scripts/local-dev.sh test-k8s

local-status: ## 📊 Show local environment status
	@echo "$(BLUE)Checking local environment status...$(NC)"
	./scripts/local-dev.sh status

local-logs: ## 📋 Show local container logs
	@echo "$(BLUE)Showing local container logs...$(NC)"
	docker logs jterrazz-infra-server

local-shell: ## 🐚 SSH into local development container
	@echo "$(GREEN)Connecting to local container...$(NC)"
	ssh ubuntu@localhost -p 2222

local-exec: ## 🔧 Execute command in local container (usage: make local-exec CMD="kubectl get nodes")
	@echo "$(GREEN)Executing in local container: $(CMD)$(NC)"
	docker exec -it jterrazz-infra-server bash -c "$(CMD)"

##@ Production Deployment

prod-check: ## 🔍 Check production deployment prerequisites
	@echo "$(BLUE)Checking production deployment prerequisites...$(NC)"
	@command -v terraform >/dev/null 2>&1 || { echo "$(RED)terraform not found$(NC)"; exit 1; }
	@command -v ansible >/dev/null 2>&1 || { echo "$(RED)ansible not found$(NC)"; exit 1; }
	@test -f terraform/terraform.tfvars || { echo "$(YELLOW)Warning: terraform.tfvars not found$(NC)"; }
	@test -f ansible/group_vars/all/vault.yml || { echo "$(YELLOW)Warning: vault.yml not found$(NC)"; }
	@echo "$(GREEN)Production deployment prerequisites OK$(NC)"

prod-plan: ## 📋 Plan Terraform infrastructure changes
	@echo "$(BLUE)Planning Terraform infrastructure...$(NC)"
	cd terraform && terraform plan

prod-deploy: ## 🚀 Deploy to production (Terraform + Ansible)
	@echo "$(GREEN)Deploying to production...$(NC)"
	./scripts/bootstrap.sh

prod-terraform: ## 🏗️  Apply Terraform infrastructure only
	@echo "$(BLUE)Applying Terraform infrastructure...$(NC)"
	cd terraform && terraform apply

prod-ansible: ## ⚙️  Run Ansible playbook against production
	@echo "$(GREEN)Running Ansible playbook on production...$(NC)"
	cd ansible && ansible-playbook -i inventories/production/hosts.yml site.yml

prod-destroy: ## 💥 Destroy production infrastructure (DANGEROUS!)
	@echo "$(RED)This will DESTROY all production infrastructure!$(NC)"
	@read -p "Are you sure? Type 'yes' to continue: " confirm; \
	if [ "$$confirm" = "yes" ]; then \
		cd terraform && terraform destroy; \
	else \
		echo "Cancelled."; \
	fi

prod-status: ## 📊 Check production infrastructure status  
	@echo "$(BLUE)Checking production infrastructure...$(NC)"
	@cd terraform && terraform show -json 2>/dev/null | jq -r '.values.root_module.resources[] | select(.type=="hcloud_server") | .values.name + ": " + .values.status' 2>/dev/null || echo "No Terraform state found"

##@ GitHub Actions

gh-deploy: ## 🐙 Trigger GitHub Actions deployment
	@echo "$(GREEN)Triggering GitHub Actions deployment...$(NC)"
	@command -v gh >/dev/null 2>&1 || { echo "$(RED)GitHub CLI (gh) not installed$(NC)"; exit 1; }
	gh workflow run deploy-infrastructure.yml -f action=deploy -f environment=production

gh-status: ## 📊 Check GitHub Actions deployment status
	@echo "$(BLUE)Checking GitHub Actions status...$(NC)"
	@command -v gh >/dev/null 2>&1 || { echo "$(RED)GitHub CLI (gh) not installed$(NC)"; exit 1; }
	gh run list --workflow=deploy-infrastructure.yml --limit=5

##@ Development Workflow

dev-full: ## 🔄 Full local development cycle (clean, start, ansible, test)
	@echo "$(GREEN)Running full local development cycle...$(NC)"
	$(MAKE) local-clean
	$(MAKE) local-start
	@sleep 10
	$(MAKE) local-ansible
	$(MAKE) local-kubeconfig
	$(MAKE) local-test

dev-quick: ## ⚡ Quick local test (start, ansible if needed)
	@echo "$(YELLOW)Running quick local test...$(NC)"
	./scripts/local-dev.sh start || true
	$(MAKE) local-ansible
	$(MAKE) local-kubeconfig

dev-reset: ## 🔄 Reset local environment (stop, clean, start)
	@echo "$(YELLOW)Resetting local environment...$(NC)"
	$(MAKE) local-stop || true
	$(MAKE) local-clean
	$(MAKE) local-start

##@ Setup and Dependencies

setup: ## 📦 Install project dependencies
	@echo "$(GREEN)Setting up local development dependencies...$(NC)"
	@command -v docker >/dev/null 2>&1 || { echo "$(RED)Please install Docker first$(NC)"; exit 1; }
	@command -v docker-compose >/dev/null 2>&1 || { echo "$(RED)Please install Docker Compose first$(NC)"; exit 1; }
	pip install ansible
	@command -v kubectl >/dev/null 2>&1 || { echo "$(YELLOW)Consider installing kubectl for easier k8s management$(NC)"; }
	@echo "$(YELLOW)Note: Helm, k3s, and other tools are installed BY Ansible INSIDE containers$(NC)"
	@echo "$(GREEN)Local development setup complete!$(NC)"

deps: ## 🔍 Check all dependencies
	@echo "$(BLUE)Checking client dependencies (what YOU need installed)...$(NC)"
	@echo "Required for local development commands:"
	@command -v docker >/dev/null 2>&1 && echo "  ✅ Docker" || echo "  ❌ Docker (required)"
	@command -v docker-compose >/dev/null 2>&1 && echo "  ✅ Docker Compose" || echo "  ❌ Docker Compose (required)"
	@command -v ansible >/dev/null 2>&1 && echo "  ✅ Ansible" || echo "  ❌ Ansible (required)"
	@echo "Required for production deployment commands:"
	@command -v terraform >/dev/null 2>&1 && echo "  ✅ Terraform" || echo "  ❌ Terraform (for make prod-* commands)"
	@echo "Optional/convenience tools:"
	@command -v kubectl >/dev/null 2>&1 && echo "  ✅ kubectl" || echo "  ⚠️  kubectl (for make k8s-* commands)"
	@command -v gh >/dev/null 2>&1 && echo "  ✅ GitHub CLI" || echo "  ⚠️  GitHub CLI (for make gh-* commands)"
	@echo "$(YELLOW)Note: Helm, k3s, etc. are installed BY Ansible INSIDE containers/servers$(NC)"

##@ Kubernetes Management

k8s-nodes: ## 📋 Show Kubernetes nodes
	@echo "$(BLUE)Showing Kubernetes nodes...$(NC)"
	@export KUBECONFIG=./local-kubeconfig.yaml && kubectl get nodes -o wide 2>/dev/null || echo "$(YELLOW)Local kubeconfig not found. Run 'make local-kubeconfig' first.$(NC)"

k8s-pods: ## 📋 Show all pods
	@echo "$(BLUE)Showing all pods...$(NC)"
	@export KUBECONFIG=./local-kubeconfig.yaml && kubectl get pods -A 2>/dev/null || echo "$(YELLOW)Local kubeconfig not found. Run 'make local-kubeconfig' first.$(NC)"

k8s-services: ## 📋 Show all services
	@echo "$(BLUE)Showing all services...$(NC)"
	@export KUBECONFIG=./local-kubeconfig.yaml && kubectl get services -A 2>/dev/null || echo "$(YELLOW)Local kubeconfig not found. Run 'make local-kubeconfig' first.$(NC)"

k8s-ingress: ## 📋 Show ingress resources
	@echo "$(BLUE)Showing ingress resources...$(NC)"
	@export KUBECONFIG=./local-kubeconfig.yaml && kubectl get ingress -A 2>/dev/null || echo "$(YELLOW)Local kubeconfig not found. Run 'make local-kubeconfig' first.$(NC)"

k8s-logs: ## 📋 Show logs for specific pod (usage: make k8s-logs POD=podname NAMESPACE=default)
	@echo "$(BLUE)Showing logs for $(POD) in $(NAMESPACE)...$(NC)"
	@export KUBECONFIG=./local-kubeconfig.yaml && kubectl logs -n $(NAMESPACE) $(POD) 2>/dev/null || echo "$(RED)Pod not found or kubeconfig not available$(NC)"

##@ Utilities

clean-all: ## 🧹 Clean everything (local env + temporary files)
	@echo "$(RED)Cleaning all temporary files and local environment...$(NC)"
	$(MAKE) local-clean || true
	rm -f local-kubeconfig.yaml kubeconfig
	rm -rf local-data/
	docker system prune -f
	@echo "$(GREEN)Cleanup complete$(NC)"

logs: ## 📋 Show logs (alias for local-logs)
	$(MAKE) local-logs

status: ## 📊 Show status (alias for local-status)  
	$(MAKE) local-status

shell: ## 🐚 Shell access (alias for local-shell)
	$(MAKE) local-shell

##@ Help

help: ## 💡 Display this help message
	@echo "$(GREEN)JTerrazz Infrastructure Makefile$(NC)"
	@echo "$(BLUE)Convenient shortcuts for local development and production deployment$(NC)"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ { printf "  $(YELLOW)%-20s$(NC) %s\n", $$1, $$2 } /^##@/ { printf "\n$(GREEN)%s$(NC)\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@echo ""
	@echo "$(BLUE)Examples:$(NC)"
	@echo "  make dev-full                    # Complete local development setup"
	@echo "  make local-ansible-tags TAGS=k3s,helm  # Run specific Ansible roles"
	@echo "  make k8s-logs POD=podname NAMESPACE=default  # Show pod logs"
	@echo "  make prod-deploy                 # Deploy to production"
	@echo ""
	@echo "$(YELLOW)For more details, see: docs/LOCAL_DEVELOPMENT.md$(NC)"
