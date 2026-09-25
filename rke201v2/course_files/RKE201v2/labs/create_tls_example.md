mkdir tls
cd tls

openssl genrsa -out server.key 2048

openssl req -new -x509 \
  -key server.key \
  -out server.crt \
  -days 365 \
  -subj "/CN=wordpress.k3s.lab"

kubectl create secret tls wp-tls-secret \
  --cert=server.crt \
  --key=server.key \
  -o yaml --dry-run=client > wp-tls-secret.yaml