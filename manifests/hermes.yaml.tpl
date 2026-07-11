apiVersion: v1
kind: Namespace
metadata:
  name: ${HERMES_NAMESPACE}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: hermes-home
  namespace: ${HERMES_NAMESPACE}
spec:
  accessModes: ["ReadWriteOnce"]
  ${STORAGE_CLASS_NAME:+storageClassName: ${STORAGE_CLASS_NAME}}
  resources:
    requests:
      storage: ${HERMES_HOME_STORAGE_SIZE}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: hermes-workspace
  namespace: ${HERMES_NAMESPACE}
spec:
  accessModes: ["ReadWriteOnce"]
  ${STORAGE_CLASS_NAME:+storageClassName: ${STORAGE_CLASS_NAME}}
  resources:
    requests:
      storage: ${HERMES_WORKSPACE_STORAGE_SIZE}
---
${TRAEFIK_BASIC_AUTH_MIDDLEWARE}
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: hermes-dashboard-login-rewrite
  namespace: ${HERMES_NAMESPACE}
spec:
  replacePath:
    path: /auth/password-login
---
apiVersion: batch/v1
kind: Job
metadata:
  name: hermes-init-config
  namespace: ${HERMES_NAMESPACE}
spec:
  template:
    spec:
      restartPolicy: OnFailure
      securityContext:
        fsGroup: ${HERMES_RUNTIME_GID}
        fsGroupChangePolicy: OnRootMismatch
      containers:
      - name: init
        image: ${HERMES_AGENT_IMAGE}
        imagePullPolicy: Always
        env:
        - name: HERMES_BOOTSTRAP_MODE
          value: "${HERMES_BOOTSTRAP_MODE}"
        - name: HERMES_ADDON_VENV
          value: "${HERMES_ADDON_VENV}"
        command: ["sh", "-c"]
        args:
        - |
          set -eu
          mkdir -p /opt/data /workspace
          bootstrap_copy_missing() {
            src="$1"
            dest="$2"
            [ -e "$src" ] || return 0
            if [ -d "$src" ]; then
              mkdir -p "$dest"
              find "$src" -mindepth 1 -print | while IFS= read -r item; do
                rel="$(printf '%s\n' "$item" | sed "s#^$src/##")"
                target="$dest/$rel"
                if [ -d "$item" ]; then
                  mkdir -p "$target"
                elif [ ! -e "$target" ]; then
                  mkdir -p "$(dirname "$target")"
                  cp -a "$item" "$target"
                fi
              done
            elif [ ! -e "$dest" ]; then
              mkdir -p "$(dirname "$dest")"
              cp -a "$src" "$dest"
            fi
          }
          bootstrap_copy_overwrite() {
            src="$1"
            dest="$2"
            [ -e "$src" ] || return 0
            mkdir -p "$(dirname "$dest")"
            if [ -d "$src" ]; then
              mkdir -p "$dest"
              cp -a "$src"/. "$dest"/
            else
              cp -a "$src" "$dest"
            fi
          }
          if [ -f /bootstrap/bootstrap.tar.gz ]; then
            rm -rf /tmp/hermes-bootstrap
            mkdir -p /tmp/hermes-bootstrap
            tar -xzf /bootstrap/bootstrap.tar.gz -C /tmp/hermes-bootstrap
            if [ "${HERMES_BOOTSTRAP_MODE}" != "disabled" ]; then
              if [ "${HERMES_BOOTSTRAP_MODE}" = "overwrite" ]; then
                bootstrap_copy_overwrite /tmp/hermes-bootstrap/opt-data /opt/data
                bootstrap_copy_overwrite /tmp/hermes-bootstrap/workspace /workspace
              else
                bootstrap_copy_missing /tmp/hermes-bootstrap/opt-data /opt/data
                bootstrap_copy_missing /tmp/hermes-bootstrap/workspace /workspace
              fi
            fi
            if [ -f /tmp/hermes-bootstrap/addons/requirements.txt ]; then
              python3 -m venv "$HERMES_ADDON_VENV"
              "$HERMES_ADDON_VENV/bin/pip" install --upgrade pip
              "$HERMES_ADDON_VENV/bin/pip" install -r /tmp/hermes-bootstrap/addons/requirements.txt
            fi
            rm -rf /tmp/hermes-bootstrap
          fi
          if [ ! -f /opt/data/config.yaml ]; then
            {
              printf '%s\n' 'provider: ${MODEL_PROVIDER}'
              printf '%s\n' 'model: ${MODEL_NAME}'
              printf '%s\n' 'agent:'
              printf '%s\n' '  verify_on_stop: false'
              printf '%s\n' 'terminal:'
              printf '%s\n' '  cwd: /workspace'
              printf '%s\n' 'display:'
              printf '%s\n' '  tool_progress: all'
              printf '%s\n' 'gateway:'
              printf '%s\n' '  host: 0.0.0.0'
              printf '%s\n' '  port: 8642'
            } > /opt/data/config.yaml
          fi
          if [ ! -f /opt/data/SOUL.md ]; then
            {
              printf '%s\n' 'You are Hermes Agent, an intelligent AI assistant. Be helpful, direct, technically precise, and security-conscious.'
              printf '%s\n' ''
              printf '%s\n' '## Browser usage policy'
              printf '%s\n' 'A real Chromium browser is available through Hermes browser tools via the `BROWSER_CDP_URL` environment variable. Use browser tools for real UI/web verification, especially WebUI issues, JavaScript-rendered pages, login flows, Ingress checks, screenshots, browser console errors, and reproducing frontend problems. Use curl for HTTP status/headers/health endpoints, but do not rely only on curl for UI problems. Never print the full `BROWSER_CDP_URL`; it contains a token.'
            } > /opt/data/SOUL.md
          fi
          chown -R ${HERMES_RUNTIME_UID}:${HERMES_RUNTIME_GID} /opt/data /workspace
          chmod 700 /opt/data
        volumeMounts:
        - name: home
          mountPath: /opt/data
        - name: workspace
          mountPath: /workspace
        - name: bootstrap
          mountPath: /bootstrap
          readOnly: true
      volumes:
      - name: bootstrap
        secret:
          secretName: hermes-bootstrap-archive
          optional: true
      - name: home
        persistentVolumeClaim:
          claimName: hermes-home
      - name: workspace
        persistentVolumeClaim:
          claimName: hermes-workspace
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hermes-agent
  namespace: ${HERMES_NAMESPACE}
spec:
  replicas: 1
  revisionHistoryLimit: 3
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: hermes-agent
  template:
    metadata:
      labels:
        app: hermes-agent
    spec:
      securityContext:
        fsGroup: ${HERMES_RUNTIME_GID}
        fsGroupChangePolicy: OnRootMismatch
      initContainers:
      - name: prepare-permissions
        image: busybox:1.36
        command: ["sh", "-c"]
        args:
        - |
          set -eu
          mkdir -p /opt/data /workspace
          chown -R ${HERMES_RUNTIME_UID}:${HERMES_RUNTIME_GID} /opt/data /workspace
          chmod 700 /opt/data
        volumeMounts:
        - name: home
          mountPath: /opt/data
        - name: workspace
          mountPath: /workspace
      containers:
      - name: hermes-agent
        image: ${HERMES_AGENT_IMAGE}
        imagePullPolicy: Always
        command: ["/init", "/opt/hermes/docker/main-wrapper.sh"]
        args: ["gateway", "run"]
        ports:
        - name: api
          containerPort: 8642
        env:
        - name: HERMES_HOME
          value: /opt/data
        - name: HERMES_WRITE_SAFE_ROOT
          value: /opt/data:/workspace
        - name: HERMES_ADDON_VENV
          value: "${HERMES_ADDON_VENV}"
        - name: PATH
          value: /opt/hermes/bin:/opt/hermes/.venv/bin:${HERMES_ADDON_VENV}/bin:/opt/data/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        - name: API_SERVER_ENABLED
          value: "true"
        - name: API_SERVER_HOST
          value: 0.0.0.0
        - name: API_SERVER_PORT
          value: "8642"
        - name: API_SERVER_KEY
          valueFrom:
            secretKeyRef:
              name: hermes-api-server
              key: api-key
        - name: BROWSER_CDP_URL
          valueFrom:
            secretKeyRef:
              name: hermes-browser-cdp
              key: BROWSER_CDP_URL
        volumeMounts:
        - name: home
          mountPath: /opt/data
        - name: workspace
          mountPath: /workspace
        readinessProbe:
          httpGet:
            path: /health
            port: api
          initialDelaySeconds: 20
          periodSeconds: 10
          failureThreshold: 18
        livenessProbe:
          httpGet:
            path: /health
            port: api
          initialDelaySeconds: 90
          periodSeconds: 20
          failureThreshold: 6
        resources:
          requests:
            cpu: ${HERMES_AGENT_CPU_REQUEST}
            memory: ${HERMES_AGENT_MEMORY_REQUEST}
          limits:
            cpu: "${HERMES_AGENT_CPU_LIMIT}"
            memory: ${HERMES_AGENT_MEMORY_LIMIT}
      volumes:
      - name: home
        persistentVolumeClaim:
          claimName: hermes-home
      - name: workspace
        persistentVolumeClaim:
          claimName: hermes-workspace
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hermes-dashboard
  namespace: ${HERMES_NAMESPACE}
spec:
  replicas: 1
  revisionHistoryLimit: 3
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: hermes-dashboard
  template:
    metadata:
      labels:
        app: hermes-dashboard
    spec:
      securityContext:
        fsGroup: ${HERMES_RUNTIME_GID}
        fsGroupChangePolicy: OnRootMismatch
      initContainers:
      - name: prepare-permissions
        image: busybox:1.36
        command: ["sh", "-c"]
        args:
        - |
          set -eu
          mkdir -p /opt/data /workspace
          chown -R ${HERMES_RUNTIME_UID}:${HERMES_RUNTIME_GID} /opt/data /workspace
          chmod 700 /opt/data
        volumeMounts:
        - name: home
          mountPath: /opt/data
        - name: workspace
          mountPath: /workspace
      containers:
      - name: hermes-dashboard
        image: ${HERMES_AGENT_IMAGE}
        imagePullPolicy: Always
        command: ["/init", "/opt/hermes/docker/main-wrapper.sh"]
        args: ["dashboard", "--host", "0.0.0.0", "--port", "9119", "--no-open"]
        ports:
        - name: dashboard
          containerPort: 9119
        env:
        - name: HERMES_HOME
          value: /opt/data
        - name: HERMES_WRITE_SAFE_ROOT
          value: /opt/data:/workspace
        - name: HERMES_DASHBOARD_FILES_ROOT
          value: /workspace
        - name: HERMES_DASHBOARD_BASIC_AUTH_USERNAME
          valueFrom:
            secretKeyRef:
              name: hermes-dashboard-auth
              key: username
        - name: HERMES_DASHBOARD_BASIC_AUTH_PASSWORD
          valueFrom:
            secretKeyRef:
              name: hermes-dashboard-auth
              key: password
        - name: GATEWAY_HEALTH_URL
          value: http://hermes-agent:8642
        - name: API_SERVER_KEY
          valueFrom:
            secretKeyRef:
              name: hermes-api-server
              key: api-key
        - name: BROWSER_CDP_URL
          valueFrom:
            secretKeyRef:
              name: hermes-browser-cdp
              key: BROWSER_CDP_URL
        volumeMounts:
        - name: home
          mountPath: /opt/data
        - name: workspace
          mountPath: /workspace
        readinessProbe:
          tcpSocket:
            port: dashboard
          initialDelaySeconds: 20
          periodSeconds: 10
          failureThreshold: 18
        livenessProbe:
          tcpSocket:
            port: dashboard
          initialDelaySeconds: 90
          periodSeconds: 20
          failureThreshold: 6
        resources:
          requests:
            cpu: ${HERMES_DASHBOARD_CPU_REQUEST}
            memory: ${HERMES_DASHBOARD_MEMORY_REQUEST}
          limits:
            cpu: "${HERMES_DASHBOARD_CPU_LIMIT}"
            memory: ${HERMES_DASHBOARD_MEMORY_LIMIT}
      volumes:
      - name: home
        persistentVolumeClaim:
          claimName: hermes-home
      - name: workspace
        persistentVolumeClaim:
          claimName: hermes-workspace
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hermes-webui
  namespace: ${HERMES_NAMESPACE}
spec:
  replicas: 1
  revisionHistoryLimit: 3
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: hermes-webui
  template:
    metadata:
      labels:
        app: hermes-webui
    spec:
      securityContext:
        fsGroup: ${HERMES_RUNTIME_GID}
        fsGroupChangePolicy: OnRootMismatch
      initContainers:
      - name: prepare-webui-state
        image: busybox:1.36
        command: ["sh", "-c"]
        args:
        - |
          set -eu
          mkdir -p /opt/data/webui /workspace
          chown -R ${HERMES_RUNTIME_UID}:${HERMES_RUNTIME_GID} /opt/data /workspace
          chmod 700 /opt/data
          chmod 700 /opt/data/webui
        volumeMounts:
        - name: home
          mountPath: /opt/data
        - name: workspace
          mountPath: /workspace
      - name: copy-agent-source
        image: ${HERMES_AGENT_IMAGE}
        imagePullPolicy: Always
        command: ["/bin/sh", "-c"]
        args:
        - >-
          set -eu;
          cp -a /opt/hermes/. /agent-src/;
          chown -R ${HERMES_RUNTIME_UID}:${HERMES_RUNTIME_GID} /agent-src;
          chmod -R go-w /agent-src
        volumeMounts:
        - name: hermes-agent-src
          mountPath: /agent-src
      - name: prepare-browser-cli
        image: ${HERMES_AGENT_IMAGE}
        imagePullPolicy: Always
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -eu
          mkdir -p /opt/data/node/bin
          cp /usr/local/bin/node /opt/data/node/bin/node
          chmod 755 /opt/data/node/bin/node
          ln -sfn /home/hermeswebui/.hermes/hermes-agent/node_modules /opt/data/node_modules
          chown -R ${HERMES_RUNTIME_UID}:${HERMES_RUNTIME_GID} /opt/data/node
        volumeMounts:
        - name: home
          mountPath: /opt/data
      containers:
      - name: hermes-webui
        image: ${HERMES_WEBUI_IMAGE}
        imagePullPolicy: Always
        ports:
        - name: web
          containerPort: 8787
        env:
        - name: HERMES_HOME
          value: /opt/data
        - name: HERMES_WRITE_SAFE_ROOT
          value: /opt/data:/workspace
        - name: HERMES_WEBUI_HOST
          value: 0.0.0.0
        - name: HERMES_WEBUI_PORT
          value: "8787"
        - name: HERMES_WEBUI_STATE_DIR
          value: /opt/data/webui
        - name: HERMES_WEBUI_AGENT_DIR
          value: /home/hermeswebui/.hermes/hermes-agent
        - name: HERMES_WEBUI_AUTO_INSTALL
          value: "1"
        - name: HERMES_WEBUI_PASSWORD
          valueFrom:
            secretKeyRef:
              name: hermes-dashboard-auth
              key: password
        - name: HERMES_WEBUI_MAX_UPLOAD_MB
          value: "${HERMES_WEBUI_MAX_UPLOAD_MB}"
        - name: PATH
          value: /opt/data/node/bin:/opt/data/node_modules/.bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
        - name: HERMES_API_URL
          value: http://hermes-agent:8642
        - name: HERMES_API_KEY
          valueFrom:
            secretKeyRef:
              name: hermes-api-server
              key: api-key
        - name: BROWSER_CDP_URL
          valueFrom:
            secretKeyRef:
              name: hermes-browser-cdp
              key: BROWSER_CDP_URL
        - name: WANTED_UID
          value: "${HERMES_RUNTIME_UID}"
        - name: WANTED_GID
          value: "${HERMES_RUNTIME_GID}"
        volumeMounts:
        - name: home
          mountPath: /opt/data
        - name: workspace
          mountPath: /workspace
        - name: hermes-agent-src
          mountPath: /home/hermeswebui/.hermes/hermes-agent
          readOnly: true
        readinessProbe:
          httpGet:
            path: /health
            port: web
          initialDelaySeconds: 30
          periodSeconds: 10
          failureThreshold: 18
        livenessProbe:
          httpGet:
            path: /health
            port: web
          initialDelaySeconds: 90
          periodSeconds: 20
          failureThreshold: 6
        resources:
          requests:
            cpu: ${HERMES_WEBUI_CPU_REQUEST}
            memory: ${HERMES_WEBUI_MEMORY_REQUEST}
          limits:
            cpu: "${HERMES_WEBUI_CPU_LIMIT}"
            memory: ${HERMES_WEBUI_MEMORY_LIMIT}
      volumes:
      - name: home
        persistentVolumeClaim:
          claimName: hermes-home
      - name: workspace
        persistentVolumeClaim:
          claimName: hermes-workspace
      - name: hermes-agent-src
        emptyDir: {}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hermes-browser
  namespace: ${HERMES_NAMESPACE}
spec:
  replicas: 1
  revisionHistoryLimit: 3
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: hermes-browser
  template:
    metadata:
      labels:
        app: hermes-browser
    spec:
      containers:
      - name: chromium
        image: ${HERMES_BROWSER_IMAGE}
        imagePullPolicy: Always
        ports:
        - name: http
          containerPort: 3000
        env:
        - name: PORT
          value: "3000"
        - name: HOST
          value: 0.0.0.0
        - name: TOKEN
          valueFrom:
            secretKeyRef:
              name: hermes-browser-token
              key: token
        - name: CONCURRENT
          value: "${BROWSER_CONCURRENT}"
        - name: QUEUED
          value: "${BROWSER_QUEUED}"
        - name: TIMEOUT
          value: "${BROWSER_TIMEOUT_MS}"
        readinessProbe:
          tcpSocket:
            port: http
          initialDelaySeconds: 10
          periodSeconds: 10
          failureThreshold: 18
        livenessProbe:
          tcpSocket:
            port: http
          initialDelaySeconds: 30
          periodSeconds: 20
          failureThreshold: 6
        resources:
          requests:
            cpu: ${HERMES_BROWSER_CPU_REQUEST}
            memory: ${HERMES_BROWSER_MEMORY_REQUEST}
          limits:
            cpu: "${HERMES_BROWSER_CPU_LIMIT}"
            memory: ${HERMES_BROWSER_MEMORY_LIMIT}
---
apiVersion: v1
kind: Service
metadata:
  name: hermes-agent
  namespace: ${HERMES_NAMESPACE}
spec:
  selector:
    app: hermes-agent
  ports:
  - name: api
    port: 8642
    targetPort: api
---
apiVersion: v1
kind: Service
metadata:
  name: hermes-dashboard
  namespace: ${HERMES_NAMESPACE}
spec:
  selector:
    app: hermes-dashboard
  ports:
  - name: dashboard
    port: 9119
    targetPort: dashboard
---
apiVersion: v1
kind: Service
metadata:
  name: hermes-webui
  namespace: ${HERMES_NAMESPACE}
spec:
  selector:
    app: hermes-webui
  ports:
  - name: web
    port: 8787
    targetPort: web
---
apiVersion: v1
kind: Service
metadata:
  name: hermes-browser
  namespace: ${HERMES_NAMESPACE}
spec:
  type: ClusterIP
  selector:
    app: hermes-browser
  ports:
  - name: http
    port: 3000
    targetPort: http
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: hermes-browser-restrict
  namespace: ${HERMES_NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app: hermes-browser
  policyTypes: ["Ingress", "Egress"]
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: hermes-agent
    - podSelector:
        matchLabels:
          app: hermes-dashboard
    - podSelector:
        matchLabels:
          app: hermes-webui
    ports:
    - protocol: TCP
      port: 3000
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
        - 10.0.0.0/8
        - 172.16.0.0/12
        - 192.168.0.0/16
        - 100.64.0.0/10
        - 127.0.0.0/8
        - 169.254.0.0/16
        - 224.0.0.0/4
    ports:
    - protocol: TCP
      port: 80
    - protocol: TCP
      port: 443
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hermes-webui
  namespace: ${HERMES_NAMESPACE}
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: ${TRAEFIK_ENTRYPOINT}
    traefik.ingress.kubernetes.io/router.tls: "${TLS_ENABLED}"
${WEBUI_BASIC_AUTH_ANNOTATION}
spec:
  ingressClassName: ${INGRESS_CLASS_NAME}
  ${TLS_SECRET_NAME:+tls:
  - hosts:
    - ${WEBUI_HOST}
    secretName: ${TLS_SECRET_NAME}}
  rules:
  - host: ${WEBUI_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: hermes-webui
            port:
              number: 8787
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hermes-dashboard
  namespace: ${HERMES_NAMESPACE}
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: ${TRAEFIK_ENTRYPOINT}
    traefik.ingress.kubernetes.io/router.tls: "${TLS_ENABLED}"
${DASHBOARD_BASIC_AUTH_ANNOTATION}
spec:
  ingressClassName: ${INGRESS_CLASS_NAME}
  ${TLS_SECRET_NAME:+tls:
  - hosts:
    - ${DASHBOARD_HOST}
    secretName: ${TLS_SECRET_NAME}}
  rules:
  - host: ${DASHBOARD_HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: hermes-dashboard
            port:
              number: 9119
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hermes-dashboard-login
  namespace: ${HERMES_NAMESPACE}
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: ${TRAEFIK_ENTRYPOINT}
    traefik.ingress.kubernetes.io/router.tls: "${TLS_ENABLED}"
${DASHBOARD_LOGIN_MIDDLEWARE_ANNOTATION}
spec:
  ingressClassName: ${INGRESS_CLASS_NAME}
  rules:
  - host: ${DASHBOARD_HOST}
    http:
      paths:
      - path: /auth/login
        pathType: Prefix
        backend:
          service:
            name: hermes-dashboard
            port:
              number: 9119
