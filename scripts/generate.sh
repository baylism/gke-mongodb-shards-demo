#!/bin/sh
##
# Script to deploy a Kubernetes project with a StatefulSet running a MongoDB Sharded Cluster, to GKE.
##

MONGO_ADMIN_PASSWORD=""
CLUSTER=""
NODE_POOL=""

# ========== Add an Ubuntu node pool to exsting GKE cluster ==========
# see https://cloudplatform.googleblog.com/2016/05/introducing-Google-Container-Engine-GKE-node-pools.html


echo Initial node pools:
gcloud container node-pools list --cluster=$CLUSTER

echo Initial nodes:
kubectl get nodes

gcloud container node-pools create $NODE_POOL \
       --cluster=$CLUSTER \
       --machine-type=n1-standard-2 \
       --image-type=ubuntu \
       --disk-size=40 \
    #    --enable-autorepair \
       --num-nodes=3

echo After creating node pool $NODE_POOL:
gcloud container node-pools list --cluster=$CLUSTER
kubectl get nodes

# after deployment, can use label selector cloud.google.com/gke-nodepool=$NODE_POOL

# ========== Run host configurere ==========
# Configure host VM using daemonset to disable hugepages
echo "Deploying GKE Daemon Set"
kubectl apply -f ../resources/hostvm-node-configurer-daemonset.yaml


# Define storage class for dynamically generated persistent volumes
kubectl apply -f ../resources/ssd-xfs-storageclass.yaml


# Create keyfile for the MongoDB cluster as a Kubernetes shared secret
TMPFILE=$(mktemp)
/usr/bin/openssl rand -base64 741 > $TMPFILE
kubectl create secret generic shared-bootstrap-data --from-file=internal-auth-mongodb-keyfile=$TMPFILE
rm $TMPFILE


# Deploy a MongoDB ConfigDB Service ("Config Server Replica Set") using a Kubernetes StatefulSet
echo "Deploying GKE StatefulSet & Service for MongoDB Config Server Replica Set"
kubectl apply -f ../resources/mongodb-configdb-service.yaml


# Deploy each MongoDB Shard Service using a Kubernetes StatefulSet
echo "Deploying GKE StatefulSet & Service for each MongoDB Shard Replica Set"
sed -e 's/shardX/shard1/g; s/ShardX/Shard1/g' ../resources/mongodb-maindb-service.yaml > /tmp/mongodb-maindb-service.yaml
kubectl apply -f /tmp/mongodb-maindb-service.yaml
sed -e 's/shardX/shard2/g; s/ShardX/Shard2/g' ../resources/mongodb-maindb-service.yaml > /tmp/mongodb-maindb-service.yaml
kubectl apply -f /tmp/mongodb-maindb-service.yaml
sed -e 's/shardX/shard3/g; s/ShardX/Shard3/g' ../resources/mongodb-maindb-service.yaml > /tmp/mongodb-maindb-service.yaml
kubectl apply -f /tmp/mongodb-maindb-service.yaml
rm /tmp/mongodb-maindb-service.yaml


# Deploy some Mongos Routers using a Kubernetes StatefulSet
echo "Deploying GKE Deployment & Service for some Mongos Routers"
kubectl apply -f ../resources/mongodb-mongos-service.yaml


# Wait until the final mongod of each Shard + the ConfigDB has started properly
echo
echo "Waiting for all the shards and configdb containers to come up (`date`)..."
echo " (IGNORE any reported not found & connection errors)"
sleep 30

until kubectl --v=0 exec mongod-configdb-2 -c mongod-configdb-container -- mongo --quiet --eval 'db.getMongo()'; do
    sleep 5
done

for i in 1 2 3
do
    until kubectl --v=0 exec mongod-shard$i-1 -c mongod-shard$i-container -- mongo --quiet --eval 'db.getMongo()'; do
        sleep 5
    done
done

echo "...shards & configdb containers are now running (`date`)"
echo


# Initialise the Config Server Replica Set and each Shard Replica Set
echo "Configuring Config Server's & each Shard's Replica Sets"

# connect to one of the config servers and initiate the config server replica set to store metadata + configs for the cluster
kubectl exec mongod-configdb-0 -c mongod-configdb-container -- mongo --eval 'rs.initiate({_id: "ConfigDBRepSet", version: 1, members: [ {_id: 0, host: "mongod-configdb-0.mongodb-configdb-service.default.svc.cluster.local:27017"}, {_id: 1, host: "mongod-configdb-1.mongodb-configdb-service.default.svc.cluster.local:27017"}, {_id: 2, host: "mongod-configdb-2.mongodb-configdb-service.default.svc.cluster.local:27017"} ]});'



# connnect to one pod in each shard and initiate the replica set 
for i in 1 2 3
do
    echo
    echo Initiating shard $i
    kubectl exec mongod-shard$i-0 -c mongod-shard$i-container -- mongo --eval 'rs.initiate({_id: "Shard${i}RepSet", version: 1, members: [ {_id: 0, host: "mongod-shard${i}-0.mongodb-shard${i}-service.default.svc.cluster.local:27017"}, {_id: 1, host: "mongod-shard${i}-1.mongodb-shard${i}-service.default.svc.cluster.local:27017"} ]});'
done

echo


# Wait for each MongoDB Shard's Replica Set + the ConfigDB Replica Set to each have a primary ready
echo "Waiting for all the MongoDB ConfigDB & Shards Replica Sets to initialise..."
kubectl exec mongod-configdb-0 -c mongod-configdb-container -- mongo --quiet --eval 'while (rs.status().hasOwnProperty("myState") && rs.status().myState != 1) { print("."); sleep(1000); };'

for i in 1 2 3
do
    echo -n Checking shard $i ...
    kubectl exec mongod-shard$i-0 -c mongod-shard$i-container -- mongo --quiet --eval 'while (rs.status().hasOwnProperty("myState") && rs.status().myState != 1) { print("."); sleep(1000); };'
    echo OK
done

sleep 2 # Just a little more sleep to ensure everything is ready!
echo "...initialisation of the MongoDB Replica Sets completed"
echo


# Wait for the mongos to have started properly
echo "Waiting for the first mongos to come up (`date`)..."
echo " (IGNORE any reported not found & connection errors)"
echo -n "  "
until kubectl --v=0 exec mongos-router-0 -c mongos-container -- mongo --quiet --eval 'db.getMongo()'; do
    sleep 2
    echo -n "  "
done
echo "...first mongos is now running (`date`)"
echo


# Add Shards to the Configdb NOTE needs admin access
echo "Configuring ConfigDB to be aware of the 3 Shards"

for i in 1 2 3
do
    kubectl exec mongos-router-0 -c mongos-container -- mongo --eval 'sh.addShard("Shard${i}RepSet/mongod-shard${i}-0.mongodb-shard${i}-service.default.svc.cluster.local:27017");'
done

sleep 3

# kubectl exec mongos-router-0 -c mongos-container -it bash
# db.getSiblingDB('admin').auth("main_admin", "045a0b06a421c786e79560ac6fd96ff1")


# TODO create client authentication? https://docs.mongodb.com/manual/tutorial/enforce-keyfile-access-control-in-existing-sharded-cluster-no-downtime/#optional-create-additional-users-for-client-applications


# Create the Admin User (this will automatically disable the localhost exception)
echo "Creating user: 'main_admin'"
kubectl exec mongos-router-0 -c mongos-container -- mongo --eval 'db.getSiblingDB("admin").createUser({user:"main_admin",pwd:"'"${MONGO_ADMIN_PASSWORD}"'",roles:[{role:"root",db:"admin"}]});'
echo


# Print Summary State
kubectl get persistentvolumes
echo
kubectl get all 
echo

