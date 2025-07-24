# AWX Installationsskript für Ubuntu 24.04

Version: **1.4**

Dieses Bash-Skript automatisiert die Installation und Konfiguration von AWX (Ansible Tower Open Source) auf einem Ubuntu 24.04-System unter Verwendung von Minikube und dem AWX Operator.

---

## Inhalt

1. [Voraussetzungen](#voraussetzungen)
2. [Funktionen](#funktionen)
3. [Installation und Nutzung](#installation-und-nutzung)
4. [Konfigurations-Variablen](#konfigurations-variablen)
5. [Systemd Port-Forward Service](#systemd-port-forward-service)
6. [Fehlerbehebung](#fehlerbehebung)
7. [Uninstallation](#uninstallation)

---

## Voraussetzungen

* Ubuntu 24.04 x86\_64
* Nicht als `root` ausführen
* Mindestens 4 CPU‑Kerne
* Mindestens 8 GB RAM
* Mindestens 40 GB freier Festplattenspeicher

Bei frischer Docker‑Installation erfolgt ein Abbruch, damit der Benutzer sich neu anmelden kann (
`newgrp docker` oder aus- und einloggen).

---

## Funktionen

* System‑Check: CPU, RAM, Diskspace
* Installation von:

  * Docker (CE)
  * kubectl
  * Minikube
* Start von Minikube mit Docker-Driver und empfohlenen Addons (Ingress, Dashboard, Metrics)
* Installation des AWX Operators (Version 2.19.1)
* Deployment einer AWX-Instanz (Version 24.6.1) im Kubernetes‑Cluster
* Warten auf die Bereitstellung aller AWX-Pods
* Abfrage und Ausgabe von Admin‑Passwort, Cluster‑IP und NodePort
* Automatisches Anlegen und Starten eines systemd‑Services, der einen Port‑Forward auf Host‑Port 8080 einrichtet

---

## Installation und Nutzung

1. Skript auf das Zielsystem kopieren, z. B. nach `/usr/local/bin/install_awx.sh`:

   ```bash\wget https://<your-repo>/install_awx.sh -O install_awx.sh
   ```

chmod +x install\_awx.sh

````
2. Skript als normaler Benutzer ausführen (nicht als root):
```bash
./install_awx.sh
````

3. Nach erfolgreichem Durchlauf ist AWX im Webbrowser erreichbar unter:

   ```
   ```

http\://<Server-IP>:8080

````

---

## Konfigurations-Variablen
Im Skript zu Beginn kannst du folgende Werte anpassen:
```bash
MINIKUBE_CPUS=4             # Anzahl der CPU‑Ker
MINIKUBE_MEMORY=8192       # Minikube RAM in MB
MINIKUBE_DISK_SIZE=40g     # Minikube Disk-Size
AWX_NAMESPACE="awx"       # Kubernetes Namespace für AWX
AWX_INSTANCE_NAME="awx"   # Name der AWX CR
AWX_OPERATOR_VERSION='2.19.1'
````

---

## systemd Port-Forward Service

Das Skript erstellt automatisch einen systemd‑Unit mit Namen `awx-portforward.service`, der beim Boot den Befehl

```ini
ExecStart=/usr/local/bin/kubectl port-forward --address 0.0.0.0 svc/awx-service 8080:80 -n awx
```

ausführt. Damit ist AWX permanent unter `http://<Server-IP>:8080` erreichbar.

### Service-Befehle

```bash
# Status prüfen
systemctl status awx-portforward.service

# Logs anzeigen
journalctl -u awx-portforward.service -f

# Bei Änderungen neu laden
systemctl daemon-reload && systemctl restart awx-portforward.service
```

---

## Fehlerbehebung

* **Service startet nicht**: Prüfe den `ExecStart`‑Pfad (`which kubectl`), passe ggf. `/usr/local/bin/kubectl` an.
* **Ports belegt**: Ändere Host‑Port in der systemd‑Unit auf freien Port.
* **Pods hängen in Init**: Logs mit `kubectl logs -c <init-container>` prüfen.
* **Service nicht gefunden**: Prüfe mit `kubectl get svc -n awx`, ob der Service korrekt angelegt wurde.

---

## Uninstallation

Ein Skript `uninstall-awx.sh` wird im Arbeitsverzeichnis erstellt. Ausführen:

```bash
./uninstall-awx.sh
```

Es löscht die AWX-Instanz, den Namespace `awx` sowie Minikube und stoppt den Port-Forward-Service.

---

