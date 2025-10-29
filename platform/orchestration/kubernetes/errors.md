# Delete namespace

## 1. Проверить все проблемные APIServices

kubectl get apiservices | grep False

## 2. Посмотреть детали конкретного APIService

kubectl get apiservice <example:v1beta1.metrics.k8s.io> -o yaml

## 3. Проверить, какие финализаторы блокируют namespace

kubectl get namespace <example:lens-metrics> -o json | jq '.spec.finalizers'

## 4. Посмотреть все ресурсы в зависшем namespace

kubectl api-resources --verbs=list --namespaced -o name | xargs -n 1 kubectl get --show-kind --ignore-not-found -n <example:lens-metrics>

## 5. Проверить условия namespace

kubectl get namespace <example:lens-metrics> -o json | jq '.status.conditions'

## Шаг 1: Удалить проблемный APIService

kubectl delete apiservice <example:v1beta1.metrics.k8s.io> --ignore-not-found=true

## Шаг 2: Если есть другие проблемные APIServices, удали их тоже

kubectl get apiservices | grep False | awk '{print $1}' | xargs kubectl delete apiservice

## Шаг 3: Теперь удали finalizers из namespace

kubectl patch namespace <example:lens-metrics> -p '{"spec":{"finalizers":null}}' --type=merge

## Шаг 4: Если всё ещё висит, финальный удар:

kubectl get namespace <example:lens-metrics> -o json | \
 sed 's/"finalizers": \[.\*\]/"finalizers": []/' | \
 kubectl replace --raw /api/v1/namespaces/lens-metrics/finalize -f -

## Перед удалением namespace всегда проверяй APIServices:

kubectl get apiservices -o json | jq '.items[] | select(.spec.service.namespace=="lens-metrics") | .metadata.name'

## Универсальный скрипт для удаления любого зависшего namespace

NS="<example:lens-metrics>"
kubectl get namespace $NS -o json | jq '.spec.finalizers = []' | kubectl replace --raw /api/v1/namespaces/$NS/finalize -f -
