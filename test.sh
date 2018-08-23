# if echo is max cool | grep -q max; then
#     echo found
# else
#     echo not found
# fi
for i in 1 2 3
do
    kubectl exec mongos-router-0 -c mongos-container -- mongo --eval 'sh.addShard("Shard${i}RepSet/mongod-shard${i}-0.mongodb-shard${i}-service.default.svc.cluster.local:27017");'
done
