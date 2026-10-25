# Sécurité

Portail ouvre des disques chiffrés et manipule des phrases de passe. Les failles de sécurité sont traitées en
priorité.

## Versions suivies

| Version | Correctifs de sécurité |
|---|---|
| 1.6.x | Oui |
| Antérieures | Non : passez à la dernière version |

## Signaler une faille

**N'ouvrez pas de ticket public pour une faille.** Signalez-la en privé avec le bouton **Report a
vulnerability** de l'onglet **Security** du dépôt GitHub.

Indiquez si possible :

- la version de Portail et le modèle de téléphone, avec sa version d'Android ;
- le type de disque : LUKS1 ou LUKS2, système de fichiers ;
- les étapes pour reproduire, ou une image de disque **sans données personnelles** ;
- l'effet constaté : fuite de données, corruption, plantage, contournement d'une protection.

Vous recevrez une réponse sous 7 jours. Une fois la faille corrigée et la version publiée, elle est décrite dans
le [journal des versions](CHANGELOG.md), avec votre nom si vous le souhaitez.

## Ce qui compte comme une faille

- Une phrase de passe, une clé maîtresse ou une clé privée SSH qui reste en mémoire après usage, ou qui est
  écrite dans un journal, un fichier ou une notification.
- Le contenu d'un disque chiffré écrit en clair sur le téléphone sans action explicite de l'utilisateur.
- Un disque ou une archive piégés qui font planter le moteur, lire ou écrire hors des limites, ou écrire hors du
  dossier choisi.
- Une écriture qui corrompt un système de fichiers jugé sain par `e2fsck`, `ntfsfix` ou `fsck.fat`.
- Un serveur SSH dont la clé d'hôte a changé et qui est accepté sans avertissement.

## Garanties visées

Les protections que Portail vise sont décrites dans la section
[Sécurité du README](README.md#sécurité).
