# Architecture cible GURISHA — multi-activités et services

Statut : spécification de conception, aucune modification de base de données effectuée par ce document.

## 1. Vision

GURISHA comporte deux espaces complémentaires :
- **GURISHA BUSINESS** : outil privé de gestion d'un établissement.
- **GURISHA SERVICES** : catalogue public de prestataires et parcours client de demande, réservation et suivi.

Un établissement peut utiliser BUSINESS sans être publié sur SERVICES. La publication sur SERVICES est facultative et soumise à validation par l'administrateur de la plateforme.

## 2. Principe central : établissement + modules

Un établissement n'est pas limité à une catégorie rigide. Il possède :
- une identité (nom, propriétaire, coordonnées, adresse, pays, devise, fuseau horaire) ;
- un ou plusieurs secteurs d'activité ;
- une liste de modules activés ;
- un état de publication publique indépendant (non demandé, en attente, approuvé, suspendu).

Les modules sont activés établissement par établissement. Une boutique classique ne voit pas les écrans fast-food ou transport. Un établissement mixte peut activer plusieurs modules.

## 3. Catalogue initial de modules

### Gestion commune
- accueil et tableau de bord ;
- utilisateurs, rôles et permissions ;
- clients et fournisseurs ;
- caisse et paiements ;
- dépenses, recettes et rapports ;
- paramètres de l'établissement.

### Commerce
- catalogue d'articles, catégories et variantes ;
- stock, lots, achats et inventaires ;
- ventes et caisse.

### Restauration et production
- menus et commandes ;
- recettes, ingrédients et emballages consommables ;
- équipements réutilisables ;
- écran de préparation/cuisine ;
- réservation et livraison de repas (extensions).

### Services et rendez-vous
- catalogue de prestations et tarifs ;
- calendrier, disponibilités et rendez-vous ;
- affectation d'employés ;
- suivi d'une prestation et encaissement.

### Transport et logistique
- chauffeurs, livreurs, déménageurs ;
- véhicules et capacités ;
- trajets, transferts aéroport et courses ;
- colis, enlèvements et livraisons ;
- devis, réservation, affectation et suivi ;
- preuve de prise en charge et de livraison.

### Production et événementiel
- commandes personnalisées ;
- matières premières et consommables ;
- étapes de fabrication ;
- événements, ressources et location de matériel.

Les modules facultatifs sont indépendants. Les stocks classiques et fast-food restent distincts tant qu'une intégration explicite n'est pas conçue.

## 4. Rôles séparés

Ne pas confondre :
- **membre d'établissement** : propriétaire, gestionnaire, caissier, préparateur, employé, chauffeur ou livreur rattaché à une entreprise ;
- **prestataire publié** : établissement ou indépendant autorisé à recevoir des demandes publiques ;
- **administrateur de plateforme** : valide, suspend et modère les prestataires et annonces ;
- **client** : recherche, demande un devis, réserve, paie et suit une commande.

Un chauffeur peut être un indépendant prestataire ou un employé d'une société de transport. Le modèle doit supporter les deux cas.

## 5. Parcours GURISHA SERVICES

1. Le client choisit une catégorie de service et saisit les détails utiles.
2. GURISHA présente les prestataires approuvés et disponibles, ou transmet une demande de devis.
3. Le prestataire accepte, refuse ou propose un tarif.
4. Le client confirme.
5. La commande suit des états adaptés au service (ex. demandée, devis envoyé, confirmée, prestataire affecté, en route, en cours, terminée, annulée).
6. Le paiement et les éventuels frais de plateforme sont enregistrés avec une piste d'audit.

Les commandes de transport doivent conserver les lieux, horaires, coordonnées utiles, détails du véhicule, passagers/colis et historique des changements. Les données personnelles ne sont visibles qu'aux personnes autorisées.

## 6. Modèle de données cible (à implémenter par migrations additives)

- `shops` reste l'entité d'établissement existante afin de préserver les liens et données.
- Ajouter des métadonnées d'activité et de configuration sans recréer les boutiques.
- Ajouter une table de modules activés par établissement.
- Ajouter des profils de prestataires et demandes de publication, séparés des rôles employés.
- Ajouter plus tard des tables métier dédiées aux rendez-vous, transport, colis, véhicules et réservations.
- Toute table métier doit porter un identifiant d'établissement ou de prestataire et appliquer RLS côté serveur.
- Les changements de statut sensibles doivent passer par des fonctions transactionnelles sécurisées.

## 7. Compatibilité et migration

- Ne jamais supprimer ou renommer les tables actuelles.
- Ne pas déplacer les produits, ventes ou données fast-food existantes.
- Les établissements déjà présents doivent conserver l'accès à leurs modules actuels pendant la migration.
- Le paramétrage des nouveaux établissements ne doit pas masquer les fonctionnalités historiques avant validation.
- Les permissions d'interface ne remplacent jamais les contrôles RLS/RPC.
- Les migrations doivent être additives, testables et exécutées une par une dans Supabase SQL Editor.

## 8. Ordre de réalisation proposé

1. Métadonnées d'établissement et activation des modules, avec compatibilité des établissements existants.
2. Écran de configuration des activités et modules, visible au propriétaire.
3. Gestion des profils prestataires et validation administrative.
4. Catalogue public GURISHA SERVICES et espace client.
5. Commandes génériques et demandes de devis.
6. Parcours spécialisés : rendez-vous, transferts aéroport, déménagement, colis et livraison.
7. Paiement en ligne, commissions, évaluations et litiges après validation des parcours de base.

Ce document est une spécification. Aucun module de transport, aucune place de marché ni aucun paiement public n'est déclaré opérationnel à ce stade.
