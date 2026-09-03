# Kubernetes Storage Diagnostics Collector

`collect-storage-info.sh` — read-only Bash-скрипт для сбора диагностики
хранилища из произвольного Kubernetes-кластера. Он собирает состояние PV,
StorageClass и других cluster-scoped ресурсов, а namespaced-ресурсы проверяет в
указанном namespace и в `kube-system`.

Скрипт ничего не исправляет и не пытается автоматически определить корневую
причину. Его задача — собрать исходные данные, необходимые для диагностики
проблем с provisioning, binding, attach/detach, mount, resize, snapshots и
CSI-драйверами, включая CSI-S3/GeeseFS.

## Быстрый запуск

Требуются Bash, `kubectl`, настроенный kubeconfig, права на чтение cluster-scoped
ресурсов и namespaced-ресурсов в целевом namespace и `kube-system`.

```bash
chmod +x collect-storage-info.sh

./collect-storage-info.sh 1h prod > storage-info.txt 2>&1
```

Первый аргумент, `1h`, передаётся в `kubectl logs --since`. Можно использовать
другие длительности, поддерживаемые `kubectl`, например `15m`, `6h` или `24h`.
Второй аргумент, `prod`, задаёт namespace приложения. Все namespaced-ресурсы
собираются из него и из `kube-system`. Если указан `kube-system`, каждый раздел
собирается один раз.

Для изменения таймаута запросов Kubernetes API задайте `REQUEST_TIMEOUT`:

```bash
REQUEST_TIMEOUT=60s ./collect-storage-info.sh 6h prod > storage-info.txt 2>&1
```

Скрипт всегда использует текущий контекст kubeconfig. Перед запуском проверьте
его явно:

```bash
kubectl config current-context
```

## Что диагностируется

Область сбора определяется типом ресурса:

| Область | Ресурсы |
|---|---|
| Весь кластер | StorageClass, PersistentVolume, VolumeAttachment, CSIDriver, CSINode, VolumeAttributesClass, VolumeSnapshotClass, VolumeSnapshotContent |
| Целевой namespace и `kube-system` | PersistentVolumeClaim, Pod, CSIStorageCapacity, VolumeSnapshot, Event, ResourceQuota, LimitRange, StatefulSet |
| Только выбранные Pod'ы из этих двух namespace | `describe` и текущие логи CSI/S3/snapshot-компонентов |

Объекты Node и previous-логи контейнеров не запрашиваются. Если целевой
namespace — `kube-system`, namespaced-разделы выполняются один раз.

### Контекст, версии и доступные API

В отчёт входят:

- текущий контекст `kubectl`;
- версии клиента и Kubernetes API server;
- ресурсы API-групп `storage.k8s.io` и `snapshot.storage.k8s.io`.

Это помогает обнаружить несовместимость версий, отсутствие snapshot CRD,
`VolumeAttributesClass`, `CSIStorageCapacity` и других необязательных API.

### StorageClass

Для всех StorageClass собираются список, `describe` и полный YAML.

Отчёт показывает:

- provisioner/CSI driver;
- `volumeBindingMode`;
- `reclaimPolicy`;
- возможность расширения тома;
- тип файловой системы и параметры драйвера;
- параметры CSI-S3: mounter, endpoint, bucket и mount options, если они заданы.

Это помогает отличить нормальный `Pending` при `WaitForFirstConsumer` от ошибки
provisioning, проверить неправильный provisioner, режим binding и настройки
расширения.

### PersistentVolume и PersistentVolumeClaim

Для PV и PVC собираются список, `describe` и полный YAML. PVC запрашиваются в
целевом namespace и в `kube-system`.

Можно проверить:

- фазы `Pending`, `Bound`, `Released` и `Failed`;
- связь PVC → PV → StorageClass;
- запрошенную и фактическую ёмкость;
- access modes и volume mode;
- reclaim policy и finalizers;
- CSI driver и volume handle;
- node affinity и topology;
- data source при восстановлении из snapshot;
- conditions незавершённого resize;
- события `ProvisioningFailed`, `ExternalProvisioning` и
  `WaitForFirstConsumer`.

### Pod-потребители томов

Собираются список и полный YAML pod'ов в целевом namespace и в `kube-system`.
Это позволяет увидеть:

- какой pod использует конкретный PVC;
- на какую ноду назначен pod;
- PVC и inline CSI volumes;
- init containers и основные containers;
- состояние pod'а, readiness и количество перезапусков;
- ошибки планирования и монтирования, отражённые в состоянии объекта.

### VolumeAttachment

Для всех VolumeAttachment собираются список, `describe` и YAML.

Диагностика охватывает:

- связь PV с нодой и CSI attacher;
- состояние `attached`;
- attach/detach errors;
- зависшие deletion timestamp и finalizers;
- multi-attach и несогласованное состояние подключения.

CSI-драйверы с `attachRequired: false`, например `ru.yandex.s3.csi`, обычно не
создают VolumeAttachment. Для них отсутствие такого объекта нормально.

### CSIDriver, CSINode и CSIStorageCapacity

Собираются список, `describe` и YAML для:

- `CSIDriver`;
- `CSINode`;
- `CSIStorageCapacity` в целевом namespace и `kube-system`;
- `VolumeAttributesClass`, если API поддерживается кластером.

По этим данным можно проверить регистрацию драйвера на каждой ноде,
`attachRequired`, `podInfoOnMount`, lifecycle modes, topology keys, attach
limits и объявленную CSI-ёмкость.

### VolumeSnapshot

Скрипт запрашивает:

- `VolumeSnapshotClass`;
- `VolumeSnapshotContent`;
- `VolumeSnapshot` в целевом namespace и `kube-system`.

Собираются связи между объектами, driver, deletion policy, readiness, restore
size, snapshot handles, finalizers и сообщения об ошибках. Если snapshot API не
установлен, соответствующие команды завершатся ошибкой, а остальные разделы
будут собраны.

### Events, ResourceQuota, LimitRange и StatefulSet

В отчёт входят:

- Events из целевого namespace и `kube-system`, отсортированные по
  `lastTimestamp`;
- ResourceQuota и их `describe`;
- LimitRange и их `describe`;
- StatefulSet и полный YAML с `volumeClaimTemplates`.

Это помогает находить ошибки provisioning/mount/attach, ограничения
`requests.storage`, лимиты количества PVC, недопустимые размеры томов и
проблемы с шаблонами PVC в StatefulSet.

### CSI-компоненты и логи

Скрипт получает имена pod'ов и контейнеров в целевом namespace и в
`kube-system`, затем выбирает кандидатов по следующим фрагментам имени pod'а
или container:

```text
csi, s3, geesefs, snapshot, provisioner, attacher, resizer,
node-driver-registrar
```

Для каждого найденного pod'а выполняются:

- `kubectl describe pod`;
- текущие логи каждого init container и обычного container;
- ограничение логов по обязательному аргументу `--since`.

Так диагностируются падения CSI sidecar'ов, потеря CSI socket, ошибки
`NodeStageVolume`/`NodePublishVolume`, проблемы FUSE и GeeseFS и ошибки доступа
к Object Storage. Состояние и причины последнего завершения контейнера остаются
доступны в `kubectl describe pod`.

## Поведение при ошибках

Каждый вызов получает `kubectl --request-timeout`, по умолчанию `30s`. Если
ресурс отсутствует, API не поддерживается, недостаточно RBAC-прав или запрос
завершается ошибкой, скрипт печатает результат и маркер:

```text
[kubectl exited with status N; collection continues]
```

После этого выполняется следующий раздел. Ошибка одной команды не прерывает
весь сбор.

`--request-timeout` ограничивает запрос к Kubernetes API.

Обычное завершение скрипта с кодом `0` не гарантирует, что доступ ко всем
ресурсам был разрешён. Проверяйте отчёт на маркеры ошибок и наличие строки:

```text
=== collection complete ===
```

## Необходимые права

Для полного отчёта нужны cluster-wide `get`/`list` на cluster-scoped ресурсы и
чтение namespaced-ресурсов в целевом namespace и `kube-system`. Полезные
предварительные проверки для запуска с namespace `prod`:

```bash
kubectl auth can-i list persistentvolumes
kubectl auth can-i list persistentvolumeclaims -n prod
kubectl auth can-i list pods -n prod
kubectl auth can-i get pods/log -n prod
kubectl auth can-i list pods -n kube-system
kubectl auth can-i get pods/log -n kube-system
kubectl auth can-i list volumeattachments.storage.k8s.io
```

Скрипту не нужны права на создание, изменение или удаление ресурсов. При
частичных правах он соберёт доступные разделы и напечатает ошибки RBAC для
остальных.

## Риски безопасности

Secret и ConfigMap напрямую не запрашиваются.

### Нагрузка на кластер и размер отчёта

Все запросы выполняются последовательно. Ограничение namespaced-запросов целевым
namespace и `kube-system` исключает cluster-wide `LIST` таких объектов, но
операции `describe`, `get -o yaml` и сбор логов всё ещё могут:

- создать заметную read-нагрузку на Kubernetes API;
- выполняться продолжительное время;
- сформировать очень большой файл;
- занять место на диске машины, с которой запущен сбор.

## Каких рисков скрипт не создаёт

При неизменённом исходном коде скрипт:

- не выполняет `kubectl apply`, `create`, `patch`, `edit`, `replace`, `delete`
  или `scale`;
- не изменяет PV, PVC, StorageClass, snapshot, pod, node и другие объекты;
- не создаёт диски, снимки или Object Storage buckets;
- не подключает и не отключает тома;
- не перезапускает и не удаляет pod'ы;
- не выполняет `kubectl exec`, `cp`, `debug` или `port-forward`;
- не читает содержимое файлов внутри контейнеров;
- не запрашивает Kubernetes Secret и ConfigMap;
- не подключается к нодам по SSH и не читает их файловую систему, `dmesg` или
  журналы kubelet;
- не вызывает `yc`, облачный API или API Object Storage;
- не устанавливает агенты, DaemonSet, CRD или другие компоненты;
- не архивирует и не загружает отчёт во внешние системы;
- не сохраняет данные самостоятельно, если вывод не перенаправлен пользователем.

Скрипт явно запускает только `kubectl`. При этом сам `kubectl` может вызвать
credential plugin, указанный в kubeconfig, чтобы получить доступ к API server.

## Ограничения

Скрипт не проверяет:

- состояние, labels, taints, capacity/allocatable и события worker-нод;
- существование и состояние соответствующего диска или bucket в облачном API;
- облачные квоты, биллинг, IAM-роли и ключи Object Storage;
- состояние mount point, FUSE-процессов и файловой системы непосредственно на
  ноде;
- логи kubelet и managed control plane;
- содержимое PVC и целостность пользовательских данных;
- логи прикладных pod'ов, если их имена не совпали с CSI-шаблонами;
- корректность данных автоматически и не формирует диагноз.

Пустой раздел также не всегда означает отсутствие проблемы: Kubernetes Events
имеют ограниченный срок хранения, текущие логи ограничены аргументом `since`, а
часть компонентов managed control plane недоступна из пользовательского
кластера.
