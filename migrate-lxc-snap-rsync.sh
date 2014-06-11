#!/bin/bash
###################" Functions "###################
is_valid_ipv4() {
	local -a octets=( ${1//\./ } )
	local RETURNVALUE=0

	# return an error if the IP doesn't have exactly 4 octets
	[[ ${#octets[@]} -ne 4 ]] && return 1

	for octet in ${octets[@]}
	do
		if [[ ${octet} =~ ^[0-9]{1,3}$ ]]
		then # shift number by 8 bits, anything larger than 255 will be > 0
			((RETURNVALUE += octet>>8 ))
		else # octet wasn't numeric, return error
			return 1
		fi
	done
	return ${RETURNVALUE}
}

is_ping_host() {
	ping -c 2 $1 &> /dev/null
	if [ $? == 0 ]
	then
		return 0
	else
		return 1
	fi
}

is_ssh_open() {
	nmap -p2222 $1 | grep "open" &> /dev/null
	if [ $? == 0 ]
	then
		return 0
	else
		return 1
	fi
}

network() {
	is_valid_ipv4 $1
	if [[ $? -gt 0 ]]
	then
		echo -e "Erreur : L'adresse ip renseignée est incorrect \t $ROUGE""[KO]""$NORMAL";
		exit 255
	else
		is_ping_host $1
		if [[ $? -gt 0 ]]
		then
			echo -e "Erreur : Le serveur de destination n'est pas joignable \t $ROUGE""[KO]""$NORMAL";
			exit 255
		else
			is_ssh_open $1
			if [[ $? -gt 0 ]]
			then
				echo -e "Erreur : Le serveur de destination n'a pas son ssh ouvert\t $ROUGE""[KO]""$NORMAL";
				exit 255
			else
				echo -e "Information :  Le serveur $1 est $VERT""[OK]""$NORMAL" pour la migration;
			fi
		fi
	fi
}

validateLxcPaquet() {
	dpkg -l | grep escolan-recia-guest-$1 | grep ii &> /dev/null
	if [ $? == 0 ]
	then
		return 0
	else
		return 1
	fi
}
validateLxcProd() {
	debconf-show escolan-recia-guest-$1 | grep true &> /dev/null
	if [ $? == 0 ]
	then
		return 0
	else
		return 1
	fi
}
listLxcLv() {
	lvs | egrep "^  $1"
	listLxcVg=($(lvs | egrep "^  $1" | awk '{print $2}' | uniq));
	for vg in ${listLxcVg[*]}
	do
		totalUsed=0;
		listLxcUsed=($(lvs | egrep "^  $1" | grep $vg |  awk '{print $4}' | cut -d"," -f1 ));
		listLxcNamed=($(lvs | egrep "^  $1" | grep $vg |  awk '{print $1}'));
		validateVgDest
		arrVgDestFree=($(ssh $SSHOPTIONS $IP 2>/dev/null vgs | grep $VGDEST | awk '{print $7}' | grep -v VG | sed "s/,/./g"));
		if [[ $arrVgDestFree == *t* ]]
		then
			vgDestFre=${arrVgDestFree:0:4}
			vgDestFree=`echo $vgDestFre | awk '{print 1000 * $1}'`
		else
			vgDestFree=${arrVgDestFree:0:4}
			vgDestFree=`echo $vgDestFree | cut -d"." -f1`
		fi
		for i in ${listLxcUsed[@]}
	   	do
			let totalUsed+=$i
		done
		if [[ $totalUsed -gt $vgDestFree ]]
		then
			echo -e "Erreur : Les lvs $ROUGE ${listLxcNamed[*]} $NORMAL de $1 prennent trop d'espace disque  pour migrer sur $VGDEST distant \t $ROUGE""[KO]""$NORMAL";
			exit 255
		else
			echo -e "Information : Les lvs $VERT ${listLxcNamed[*]} $NORMAL de $1 peuvent être migrés sur $VGDEST distant \t $VERT""[OK]""$NORMAL";
		fi
	done
}

lxc() {
	validateLxcPaquet $1
	if [[ $? -gt 0 ]]
	then
		echo -e "Erreur : Cette lxc $1 n'est pas installé sur ce serveur \t $ROUGE""[KO]""$NORMAL";
		exit 255
	else
		validateLxcProd $1
		if [[ $? -gt 0 ]]
		then
			echo -e "Erreur : Cette lxc $1 n'est pas en production sur ce serveur \t $ROUGE""[KO]""$NORMAL";
			exit 255
		else
			echo "Information : La lxc $1 contient : "
			listLxcLv $1
		fi
	fi
}

validateVgDest() {
	arrVgDest=($(ssh $SSHOPTIONS $IP 2>/dev/null vgs | awk '{print $1}' | grep -v VG));
	if [[ -z "$arrVgDest" ]]
	then
		echo -e "Erreur : Il n'y a pas de volume groupe de disponible sur le serveur distant \t $ROUGE""[KO]""$NORMAL";
		exit 255
	else
		if [[ ${#arrVgDest[*]} -eq 1 || $lxc == *rootfs* || $lxc == *srv* ]]
		#if [[ ${#arrVgDest[*]} -eq 1 ]]
		then
			VGDEST=${arrVgDest[0]}
		else
			#echo "Il y a ${#arrVgDest[*]} VG sur le serveur distant"
			#PS3="Choix : "
			#echo "Veuillez choisir le VG de destination :"
			#select VGDEST in ${arrVgDest[*]}; do echo $VGDEST > /dev/null; break; done
			VGDEST=${arrVgDest[1]}
		fi
	fi

}

snapshot() {
	echo -e "Information : Pour la migration du lv de $VERT $lxc $NORMAL";
	echo -e "Taille du lv : $VERT $lxcLvSize $NORMAL";
	echo -e "Vg source : $VERT $lxcVgSource $NORMAL";
	validateVgDest
	echo -e "Vg de destination : $VERT $VGDEST $NORMAL";
	echo -e ""
	echo -e "Creation du lv de snapshot"
	lvcreate -L200M -s -n dbbackup /dev/mapper/$lxcVgSource-$lxc
	echo -e "Creation du lv $lxc sur le serveur distant"
	ssh $SSHOPTIONS $IP 2>/dev/null lvcreate $VGDEST -n $lxc -L $lxcLvSize"G"
	echo -e "Copie du lv $lxc sur le lv distant"
	dd if=/dev/mapper/$lxcVgSource-dbbackup bs=256k | ssh $SSHOPTIONS $IP 2>/dev/null dd of=/dev/mapper/$VGDEST-$lxc
	echo -e "Suppression du lv de snapshot"
	lvremove -f /dev/mapper/$lxcVgSource-dbbackup
}

sync() {
	echo -e "Information : Pour la migration du lv de $VERT $lxc $NORMAL";
	echo -e "Taille du lv : $VERT $lxcLvSize $NORMAL";
	echo -e "Vg source : $VERT $lxcVgSource $NORMAL";
	validateVgDest
	echo -e "Vg de destination : $VERT $VGDEST $NORMAL";
	echo -e ""
	echo -e "Creation du lv $lxc sur le serveur distant"
	ssh $SSHOPTIONS $IP 2>/dev/null lvcreate $VGDEST -n $lxc -L $lxcLvSize"G"
	echo -e "Formatage du lv $lxc sur le serveur distant"
	ssh $SSHOPTIONS $IP 2>/dev/null mkfs.ext4 -m1 /dev/mapper/$VGDEST-$lxc
	echo -e "Creation du repertoire temporaire"
	mkdir /var/tmp/$lxc
	echo -e "Montage du lv $lxc dans le repertoire temporaire"
	mount /dev/mapper/$lxcVgSource-$lxc /var/tmp/$lxc
	echo -e "Creation du repertoire temporaire sur le serveur distant"
	ssh $SSHOPTIONS $IP 2>/dev/null mkdir  /var/tmp/$lxc
	echo -e "Montage du lv $lxc dans le repertoire temporaire sur le serveur distant"
	ssh $SSHOPTIONS $IP 2>/dev/null mount  /dev/mapper/$VGDEST-$lxc /var/tmp/$lxc
	echo -e "Synchronisation des fichiers entre les deux lvs"
	rsync -av --numeric-ids -e "ssh $SSHOPTIONS" /var/tmp/$lxc/* $IP:/var/tmp/$lxc/
	echo -e "Démontage du repertoire temporaire sur le serveur distant"
	ssh $SSHOPTIONS $IP 2>/dev/null umount /var/tmp/$lxc
	echo -e "Démontage du repertoire temporaire"
	umount /var/tmp/$lxc
}

validateLxcLv(){
	arrLxcLvName=($(lvs | grep $LXCNAME | awk '{print $1}'));
	#arrLxcLvSize=($(lvs | grep $LXCNAME | awk '{print $4}'));
	for lxc in ${arrLxcLvName[*]}
	do
		lxcLvSize=$(lvs | grep $lxc | awk '{print $4}' | cut -d"," -f1);
		lxcVgSource=$(lvs | grep $lxc | awk '{print $2}');
		#echo $lxc " => "$lxcLvSize;
		if [[ $lxcLvSize -gt 5 ]]
		then
			echo "Migration via rsync"
			sync
		else
			echo "Migration via snapshot"
			snapshot
		fi
	done
}

###################" Variable "###################

SSHOPTIONS="-p2222 -i /etc/ssh/id_rsa-backupd -o StrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"

#Coloration
VERT="\\033[1;32m"
NORMAL="\\033[0;39m"
ROUGE="\\033[1;31m"
ROSE="\\033[1;35m"
BLEU="\\033[1;34m"
BLANC="\\033[0;02m"
BLANCLAIR="\\033[1;08m"
JAUNE="\\033[1;33m"
CYAN="\\033[1;36m"


echo -n "Entrer l'adresse ip du serveur de destination : "
read IP
network ${IP}
echo -n "Entrer le nom de la lxc à migrer : "
read LXCNAME
lxc ${LXCNAME}
validateLxcLv
echo -e "Vous devez maintenant installer la lxc sur le serveur distant"
echo -e "$VERT apt-get install escolan-recia-guest-$LXCNAME $NORMAL"
echo -e "Une fois installé vous devez redemarrer la lxc sur le serveur distant"
echo -e "$VERT escolan-vm -a stop $LXCNAME$RNE && escolan-vm -a start $LXCNAME$RNE $NORMAL"
echo -e "Pendant le demarrage de la lxc sur le serveur distant, il faut couper la lxc de ce serveur"
echo -e "$VERT escolan-vm -a stop $LXCNAME$RNE $NORMAL"
echo -e "Supprimer le lien dans /etc/service pour eviter tout redemarrage automatique"
echo -e "$VERT rm -f /etc/service/$LXCNAME$RNE $NORMAL"
