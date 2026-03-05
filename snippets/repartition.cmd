docker exec kafka1 kafka-topics --bootstrap-server kafka1:12091 --alter --topic lob_events --partitions 4
docker exec kafka1 kafka-topics --bootstrap-server kafka1:12091 --describe --topic lob_events | grep PartitionCount
