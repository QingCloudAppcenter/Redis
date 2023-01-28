# Current Operator version

ZONE ?= pek3 
KEYPAIR ?= ""
VXNET ?= ""
IMAGE_ID ?= focal5x64
INSTANCE_NAME ?= redis-build # Ubuntu Server 20.04.5 LTS 64bit
IMAGE_NAME ?= redis-base-demo
APPCENTER_REDIS_PASSWORD ?= password

define initVM
	@INSTANCES="$(call getInstance)"; \
	INSTANCE="$$(echo $${INSTANCES} | xargs -n1 | sed -n "1p")"; \
	for i in $$(echo $${INSTANCES} | xargs -n1 | sed '1d'); do \
		echo "delete instance $${i}"; \
		qingcloud iaas terminate-instances -i $${i}; \
	done; \
	if [ -n "$${INSTANCE}" ]; then \
		qingcloud iaas reset-instances -z $(ZONE) --instances $${INSTANCE} --login_mode keypair --login_keypair=$(KEYPAIR); \
		for i in $$(seq 600); do \
			ststus="$$(qingcloud iaas describe-instances -m $(IMAGE_ID) -z $(ZONE) -i $${INSTANCE} --status running | jq -r '.total_count' )"; \
			if [ $${ststus} = "0" ]; then \
				action="$$(qingcloud iaas start-instances -z $(ZONE) --instances $${INSTANCE}| jq -r '.action')"; \
				[ "$${action}" = "StartInstancesResponse" ] && break; \
				sleep 2; \
			else \
				break; \
			fi; \
		done; \
	else \
		INSTANCE="$$(qingcloud iaas run-instances --instance_class=101 --cpu=1 --memory=1024 \
						--instance_name=$(INSTANCE_NAME) --image_id=$(IMAGE_ID) \
						--zone=$(ZONE) --vxnets=$(VXNET) \
						--login_mode=keypair --login_keypair=$(KEYPAIR) \
						| jq -r ".instances[]")"; \
	fi; \
	sleep 10; \
	ip="$$(qingcloud iaas describe-instances -i $${INSTANCE} | jq -r .instance_set[].vxnets[].private_ip)"; \
	for i in $$(seq 600); do \
		nc -w1 -v $${ip} 22 && break; \
		sleep 1; \
	done
endef

define capture
	instance=$(call getInstance) ; \
	qingcloud iaas stop-instances -z $(ZONE) --instances $${instance}; \
	for i in $$(seq 30 | xargs); do \
		imageId=$$(qingcloud iaas capture-instance -i "$${instance}" --image_name="$(IMAGE_NAME)" | jq -r '.image_id'); \
		if [ "$${imageId}" != "null" ]; then \
			echo "Image ID: $${imageId}"; \
			sed -i "/\"image\"/s/img-\w*/$${imageId}/g" $(1) ; \
			break; \
		fi; \
		qingcloud iaas stop-instances -z $(ZONE) --instances $${instance}; \
		sleep 5; \
	done
endef

define getInstance
$(shell qingcloud iaas describe-instances -m $(IMAGE_ID) -z $(ZONE) | jq -r '.instance_set[] | select( .vxnets[0].vxnet_id == "$(VXNET)" and .instance_name == "redis-build" ) | .instance_id')
endef

define getIP
$(shell qingcloud iaas describe-instances -m $(IMAGE_ID) -z $(ZONE) | jq -r '.instance_set[] | select( .vxnets[0].vxnet_id == "$(VXNET)" and .instance_name == "redis-build" ) | .vxnets[0].private_ip')
endef

define log
	@echo 
	@echo "$@"
	@echo "============================="
endef

standalone:
	$(call log, "init a VM")
	$(call initVM)
	@echo "Successfully created"
	$(call log, "write hosts file")
	@echo "[redis-standalone]\n$(call getIP)" > hosts
	@if [ "$(filter online, $(MAKECMDGOALS))" = "online" ]; then \
		echo "[online-setup]\n$(call getIP)" >> hosts; \
	fi
	$(call log, "ansible install")
	ansible-playbook -i hosts --extra-vars "password=$(APPCENTER_REDIS_PASSWORD)" make.yml
	$(call log, "capture instance")
	$(call capture,../app-standalone/cluster.json.mustache)


cluster:
	$(call log, "init a VM")
	$(call initVM)
	@echo "Successfully created"
	$(call log, "write hosts file")
	@echo "[redis-cluster]\n$(call getIP)" > hosts
	if [ "$(filter online, $(MAKECMDGOALS))" = "online" ]; then \
		echo "[online-setup]\n$(call getIP)" >> hosts; \
	fi
	$(call log, "ansible install")
	ansible-playbook -i hosts make.yml
	$(call log, "capture instance")
	$(call capture,../app-cluster/cluster.json.mustache)

online:

clean:
	clean_instances="$$(qingcloud iaas describe-instances -z $(ZONE) | jq -r '.instance_set[] | select( .vxnets[0].vxnet_id == "$(VXNET)" and .instance_name == "redis-build" ) | .instance_id')"; \
	echo "terminate-instances: '$${clean_instances}'"; \
	for instance in $$(echo "$${clean_instances}" | xargs);do \
		qingcloud iaas terminate-instances -i $${instance};\
	done


