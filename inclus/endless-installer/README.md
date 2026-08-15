# EndlessClient — installeur automatique

Un seul script installe la totalité de la stack Poly+ sur un serveur Debian 12 /
Ubuntu 24.04 nu, et écrit à la fin un fichier récapitulant tous les identifiants
qu'il a générés.

C'est l'automatisation de [`DEPLOYMENT.md`](../../DEPLOYMENT.md). Le runbook
manuel reste la référence pour comprendre *pourquoi* chaque étape existe.

---

## Ce qui est déployé

| Hôte | Sert | Backé par | Port local |
| --- | --- | --- | --- |
| `endlessclient.dev` | Boutique | `plus-website` (Next.js) | 3000 |
| `www.endlessclient.dev` | Redirection 301 | — | — |
| `api.endlessclient.dev` | API + WebSocket | `plus-backend` (Rust) | 8080 |
| `admin.endlessclient.dev` | Dashboard admin | `plus-admin-dashboard` (statique) | — |
| `cdn.endlessclient.dev` | Assets cosmétiques | MinIO | 9000 |

Jamais exposés, uniquement en loopback : PostgreSQL `5432`, service de rendu
`8090`, console MinIO `9001`. Le pare-feu n'ouvre que SSH, 80 et 443.

`cdn.` **doit** être joignable publiquement : l'API distribue des URL présignées
construites à partir de cet hôte. S'il pointe sur `localhost`, toutes les images
cosmétiques renvoient 404, dans le navigateur comme en jeu.

---

## Avant de lancer

1. Un serveur Debian 12 ou Ubuntu 24.04, accès root, ~4 Go de RAM (la
   compilation Rust est le moment le plus gourmand).
2. Les 5 enregistrements DNS de type A pointant sur le serveur :

   ```
   endlessclient.dev.        A   217.144.154.148
   www.endlessclient.dev.    A   217.144.154.148
   api.endlessclient.dev.    A   217.144.154.148
   admin.endlessclient.dev.  A   217.144.154.148
   cdn.endlessclient.dev.    A   217.144.154.148
   ```

   Le script les vérifie et refuse d'appeler certbot s'ils ne résolvent pas —
   Let's Encrypt échouerait, et les échecs répétés déclenchent une limitation
   côté ACME.

---

## Lancer

```bash
unzip endless-installer.zip
cd endless-installer
chmod +x install.sh
sudo ./install.sh --email vous@exemple.com --admin-name VotrePseudo --yes
```

Compter 20 à 45 minutes : la compilation du backend en `--release` domine.

### Options utiles

| Option | Effet |
| --- | --- |
| `--domain <dom>` | Autre domaine racine (défaut `endlessclient.dev`) |
| `--email <mail>` | Contact Let's Encrypt (défaut `admin@<domaine>`) |
| `--stripe-secret <sk_…>` | Clé Stripe ; sans elle aucun cosmétique ne peut être créé |
| `--stripe-webhook-secret <whsec_…>` | Secret de signature du webhook |
| `--admin-uuid <uuid>` / `--admin-name <pseudo>` | Premier administrateur Minecraft |
| `--src-dir <chemin>` | Réutilise un checkout au lieu de cloner |
| `--skip-tls` | Tout en HTTP, DNS pas encore propagé |
| `--skip-render` | Pas de génération de couvertures (pas de Chromium) |
| `--seed-demo` | Charge le catalogue de démo — **TRUNCATE** les tables cosmétiques |
| `--patch-polyplus` | Réécrit `BackendUrl.kt` vers `https://api.<domaine>` |

`./install.sh --help` liste tout.

### Relancer

Le script est rejouable. Les secrets déjà générés sont relus depuis
`/opt/endless/secrets/` au lieu d'être régénérés — sans quoi une seconde
exécution invaliderait les mots de passe déjà posés dans PostgreSQL et MinIO.
Relancer sert à mettre à jour les sources, recompiler, ou repasser en HTTPS
après avoir corrigé le DNS.

---

## Le fichier d'identifiants

Écrit en fin d'exécution :

```
/opt/endless/secrets/IDENTIFIANTS.txt      (0600 root:root)
```

Il contient les adresses des 5 hôtes et **tous** les secrets générés :

- les **deux** barrières du dashboard admin, distinctes : l'authentification HTTP
  qui protège la page, et le mot de passe API qui protège `/cosmetics/manage/*` ;
- l'utilisateur, le mot de passe et l'URL PostgreSQL ;
- les identifiants MinIO root et la clé applicative dédiée à l'API ;
- l'état Stripe et l'URL de webhook à déclarer ;
- les commandes d'exploitation courantes.

Le lire, puis le sortir du serveur :

```bash
sudo cat /opt/endless/secrets/IDENTIFIANTS.txt
scp root@endlessclient.dev:/opt/endless/secrets/IDENTIFIANTS.txt .
```

Recopiez-le dans un gestionnaire de mots de passe et supprimez-le du serveur.
**Il n'a rien à faire dans une archive livrée ni dans un dépôt git.**

---

## Après l'installation

1. **Stripe.** Renseigner la clé et déclarer le webhook sur
   `https://api.endlessclient.dev/stripe/webhook`, abonné à exactement trois
   évènements : `checkout.session.completed`,
   `checkout.session.async_payment_succeeded`, `charge.refunded`. Puis
   `sudo systemctl restart endless-backend`.

   Un secret de webhook erroné échoue de la pire façon : les paiements passent et
   les cosmétiques ne sont jamais attribués.

2. **Sauvegardes.** Une tâche quotidienne écrit dans `/var/backups/endless`
   (dump PostgreSQL + miroir du bucket). Une sauvegarde sur le même disque n'en
   est pas une : copiez-la ailleurs, et répétez une restauration au moins une
   fois.

3. **Certificat.** `sudo certbot renew --dry-run`.

---

## Ce que le script fait au dépôt

Deux modifications de sources, nécessaires et signalées à l'exécution :

- **`plus-admin-dashboard`** — le sélecteur de backend est compilé en dur et ne
  propose que `127.0.0.1:8080` et `plus.polyfrost.org`. Le script remplace la
  seconde valeur par `https://api.<domaine>` avant de builder ; sans cela le
  dashboard déployé interroge le serveur de Polyfrost, pas le vôtre.
- **`PolyPlus/BackendUrl.kt`** — seulement avec `--patch-polyplus`. Le mod doit
  ensuite être recompilé, et il ne compile pas contre le OneConfig de ce dépôt
  (il épingle `1.1.4`, l'arbre est en `1.1.7-dev`). Voir `DEPLOYMENT.md` §21.

---

## Limites connues

- **Pas de désinstalleur.** Retirer le déploiement se fait à la main : unités
  systemd `endless-*`, `/opt/endless`, base `endless_plus`, bucket
  `endless-cosmetics`, vhost nginx `endlessclient`.
- **Aucun cosmétique ne peut être créé sans Stripe valide** : un téléversement
  provisionne un produit et un prix. Un catalogue existant se sert normalement.
- **`--seed-demo` fait un `TRUNCATE`** des tables cosmétiques, et les textures
  correspondantes ne sont pas dans le bucket : les entrées chargées renvoient 404
  tant qu'elles ne sont pas re-téléversées. C'est une aide de démo, pas des
  données de production.
- **Un seul serveur.** Pas de haute disponibilité, pas de répartition de charge.
  Ne jamais faire tourner deux backends sur la même base : les migrations
  s'appliquent au démarrage.

---

## Dépannage

```bash
journalctl -u endless-backend -f          # API
journalctl -u endless-shop -n 100         # boutique
journalctl -u endless-render -n 100       # rendu des couvertures
tail -f /var/log/endless-install.log      # trace complète de l'installation
nginx -t                                  # configuration du proxy
systemctl status endless-backend endless-shop minio postgresql nginx
```

Le tableau de symptômes de `DEPLOYMENT.md` §19 couvre les pannes classiques :
images qui 404, catalogue vide, erreurs CORS, WebSocket qui reconnecte en
boucle, achats qui n'attribuent rien.
