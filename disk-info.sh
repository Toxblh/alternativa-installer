#!/bin/bash


# Функция для конвертации размера в байтах в вид, соответствующий СИ
convert_to_si() {
    local -i bytes=$1
    local -a units=(EB PB TB GB MB KB B)
    local -a values=(10**18 10**15 10**12 10**9 10**6 10**3 1)

    for (( i=0; i<${#units[@]}; i++ )); do
        if (( bytes >= ${values[$i]} )); then
            echo "$(( bytes / ${values[$i]} ))${units[$i]}"
            return
        fi
    done
}

get_pci_address() {
    local disk=$1
    local pci_address=""

    device_path="/sys/block/${disk}"

    # Определяем, является ли устройство NVMe
    if [[ "$disk" == nvme* ]]; then
        # Для устройств NVMe, полный PCI адрес можно найти в пути к родительскому устройству
        pci_path=$(realpath "$device_path/device/../..")
    else
        # Поднимаемся вверх по дереву sysfs, пока не найдем путь, содержащий 'pci'
        while [ "$device_path" != "/" ] && [ ! -d "$device_path/pci" ] && [ ! -L "$device_path/device" ]; do
            device_path=$(dirname "$device_path")
        done

        if [ -L "$device_path/device" ]; then
            # Переходим к PCI устройству
            pci_path=$(realpath "$device_path/device")
        fi
    fi

    # Получаем PCI адрес устройства
    if [ -n "$pci_path" ] && [ -d "$pci_path" ]; then
        pci_address=${pci_path##*/}
        echo $pci_address
    else
        echo "not found."
    fi
}

getOS() {
    local disk=$1

    # Сначала создайте каталог для монтирования
    sudo mkdir /mnt/disk_probe 2>/dev/null

    for part in $(lsblk -lno NAME,TYPE /dev/$disk | grep 'part' | awk '{print $1}'); do
    # Примонтируем каждый раздел в /mnt/disk_probe для анализа
        sudo mount /dev/$part /mnt/disk_probe 2>/dev/null
        
        # ls /mnt/disk_probe/

        # Проверяем Windows, от наличия Windows директории
        if [[ -e /mnt/disk_probe/Windows/System32 ]]; then
            echo "/dev/$part contains Windows"
        # Проверяем Linux по наличию характерных директорий и файлов
        elif [[ -d /mnt/disk_probe/etc || \
                -d /mnt/disk_probe/@/etc || \
                -f /mnt/disk_probe/bin/bash || \
                -f /mnt/disk_probe/@/bin/bash || \
                -e /mnt/disk_probe/@/usr/lib/os-release || \
                -e /mnt/disk_probe/usr/lib/os-release ]]; then
            echo "/dev/$part possibly contains Linux"
            DISTRIBUTIVE=""
            # Попробуем определить дистрибутив, ищем в подходящих местах
            for os_release in /etc/os-release /@/etc/os-release /usr/lib/os-release /@/usr/lib/os-release; do
                if [[ -e /mnt/disk_probe/${os_release} ]]; then
                    DISTRIBUTIVE=$(grep '^PRETTY_NAME' /mnt/disk_probe/${os_release} | cut -d '"' -f 2)
                    break
                fi
            done
            
            if [[ ! -z "$DISTRIBUTIVE" ]]; then
                echo "Identified Linux distro: $DISTRIBUTIVE on /dev/$part"
            # else
                # echo "Could not identify the Linux distro on /dev/$part"
            fi
        # Проверяем macOS, по уникальным файлам macOS
        elif [[ -e /mnt/disk_probe/System/Library/Kernels/kernel ]]; then
            echo "/dev/$part contains macOS"
        # else
        #     echo "OS on /dev/$part could not be determined"
        fi
        
        # Отмонтируем раздел
        sudo umount /mnt/disk_probe 2>/dev/null
    done

    # Очистка
    sudo rmdir /mnt/disk_probe
}

# Получить список всех дисков без разделов
for disk in $(lsblk -d -o NAME --noheadings); do
    echo "Информация о диске /dev/$disk:"
    
    # Получить информацию о модели и серийном номере через lsblk
    modelLB=$(lsblk -n -o MODEL /dev/"$disk")
    serialLB=$(lsblk -n -o SERIAL /dev/"$disk")

    # Если lsblk заполнил переменные, используйте его вывод
    if [ -n "$modelLB" ] && [ -n "$serialLB" ]; then
        echo "Название модели диска: $modelLB"
        echo "Серийный номер диска: $serialLB"
    else
        # Если lsblk не вернул информацию, используйте smartctl
        modelSC=$(sudo smartctl -i /dev/"$disk" | awk '/Device Model|Model Number/{print $3,$4,$5,$6}')
        serialSC=$(sudo smartctl -i /dev/"$disk" | awk '/Serial Number/{print $3}')
        
        echo "Название модели диска: $modelSC"
        echo "Серийный номер диска: $serialSC"
    fi
    
    # Определить тип диска, учитывая nvme и ssd
    if [[ $disk == nvme* ]]; then
        type="nvme"
    else
        type=$(cat /sys/block/"$disk"/queue/rotational)
        type=$(($type == 0 ? "ssd" : "hdd"))
    fi
    echo "Тип диска: $type"
    
    if [ -d "/sys/class/block/$disk/queue/rotational" ] && [ $(cat /sys/class/block/$disk/queue/rotational) -eq 1 ]; then
        disk_type="HDD"
    else
        # Проверяем, является ли физическое устройство NVMe
        if [ -d "/sys/class/nvme/$disk" ]; then
            disk_type="NVMe"
        else
            disk_type="SSD"
        fi
    fi
    echo "Тип: $disk_type"

    # Получить размер диска в СИ
    size_bytes=$(sudo blockdev --getsize64 /dev/"$disk")
    echo "Размер диска: $(convert_to_si $size_bytes)"
    
    # Получить информацию о разметке (GPT или MBR)
    partition_table_type=$(sudo parted /dev/"$disk" print | awk '/Partition Table/{print $3}')
    echo "Разметка: $partition_table_type"
    
    # Получение информации о файловых системах
    filesystems=$(lsblk -no FSTYPE /dev/"$disk" | awk '{ if ($1) print $1 }' | sort -u | tr '\n' '/')
    echo "Файловые системы: ${filesystems%/}"
    
    # Получить PCI Express адрес для nvme, иначе обычный путь
    echo "PCI Express адрес (lspci): $(get_pci_address $disk)"
    
    # Определение возможной установленной ОС
    
    echo "Установленная операционная система: $(getOS $disk)"

    # echo "Checking disk /dev/$disk..."
    # for part in $(lsblk -lno NAME,TYPE /dev/$disk | grep 'part' | awk '{print $1}'); do
    #     # Fetch the file system type of the partition
    #     fstype=$(sudo blkid -o value -s TYPE /dev/$part)
    #     case "$fstype" in
    #         ntfs)
    #             echo "/dev/$part might have Windows installed."
    #             ;;
    #         ext3|ext4|btrfs|reiserfs|jfs|xfs|zfs|ufs|f2fs)
    #             echo "/dev/$part might have Linux installed."
    #             echo "Operating system: $(lsblk -f /dev/$part -o LABEL,FSTYPE,MOUNTPOINT | grep -i boot | awk '{print $2}')"
    #             ;;
    #         hfs|hfsplus|apfs)
    #             echo "/dev/$part might have macOS installed."
    #             ;;
    #         *)
    #             echo "/dev/$part has an unrecognized file system type $fstype"
    #             ;;
    #     esac
    # done
    
    echo "" # Пустая строка для разделения вывода
done

