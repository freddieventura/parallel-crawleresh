```
 ____                 _ _      _  
|  _ \ __ _ _ __ __ _| | | ___| | 
| |_) / _` | '__/ _` | | |/ _ \ | 
|  __/ (_| | | | (_| | | |  __/ | 
|_|   \__,_|_|  \__,_|_|_|\___|_| 
                                  
  ____                    _                    _      
 / ___|_ __ __ ___      _| | ___ _ __ ___  ___| |__   
| |   | '__/ _` \ \ /\ / / |/ _ \ '__/ _ \/ __| '_ \  
| |___| | | (_| |\ V  V /| |  __/ | |  __/\__ \ | | | 
 \____|_|  \__,_| \_/\_/ |_|\___|_|  \___||___/_| |_| 
                                                      

```

# Parallel-crawleresh

Parallel web crawler written in bash.

This utility will download a list of links in a `.csv`, load balancing the process with other hosts that you share a LAN connection with but that have other WAN Gateway (hence multiplying the bandwidth)


Say you have to download a huge list of files, and you have more than 1 Access Point (WAN) Gateway, you can set up this process load balancing. The process gets executed by the host we call `MASTER_HOST` and the other hosts that cooperate with the download we call them `WORKER_HOST`
You can set up as many `WORKER_HOST`'s as desired.

Requirements:
    - All hosts can reach each other in one LAN Subnet 
    - Each of the hosts have a different WAN Gateway (Desired)

See the graph below for clarity

```


             WAN2   ___________
             +---->|WORKER_HOST|
 __________ /       -----------|
|RESOURCE  | WAN1   ___________v
|SERVER    |------>|MASTER_HOST| LAN
 ----------         -----------^
           \ WAN3   ___________|
            +----->|WORKER_HOST|
                    ----------- 

                    (....)

```

Each file is been downloaded by either of the hosts, at the end of the transmision or upon running of space in the `WORKER_HOST` , they will dump their downloaded files to `MASTER_HOST`.
Disk limit is setted to `500 MB` can be changed

## Command Help

```
fakuve@elitebook-x360:~/myrepos/freddieventura/parallel-crawleresh$ ./parallel-crawleresh.sh -h
Usage: ./parallel-crawleresh.sh -r <return_host> -f <url_list_file> -n <project_name> -w <worker_host> [-w <worker_host>]...

Arguments:
  -r <return_host>   The SSH connection string of the return host (username@IP:port).
  -f <url_list_file> The file containing a list of URLs to be processed.
  -n <project_name>  The name of the project.
  -w <worker_host>   Specify a worker host in the format username@IP:port.
                      At least one -w option is required.
  -h                 Show this help message.

Example:
  ./parallel-crawleresh.sh -r userName@10.7.0.6:22 -f https___shopify.dev.csv -n MyProject -w 190.60.50.60:80 -w 127.0.0.1

This script performs parallel downloading of URLs from the specified list across multiple servers (worker_hosts).
It works with SSH and rsync, so the port specified must be the one SSH is served on each host (omit to use the default one 22).
You must specify at least one worker host with the -w option.
Note: By default, localhost will not be used as a worker host; if desired, specify it with -w 127.0.0.1.

- First Time Installation
To prepare the system for these scripts you need to add 2 environment variables on each worker_host:

$ sudo vi /home/myuser/.bashrc
export MAIN_DISK=/dev/sda
export DOWN_PATH=/home/myuser/downloads

$ vi /home/myuser/.ssh/environment
MAIN_DISK=/dev/sda
DOWN_PATH=/home/myuser/downloads

Changing the following Directive:
$ sudo vi /etc/ssh/sshd_config
PermitUserEnvironment yes
```

## Real life scenario

Infrastuctures may vary , but it is really unlikely that you have Hosts sharing the same LAN in one NIC and in other having a separate internet connection.
The most likely scenario is that you gonna have one `VPN` sharing a LAN network, but this VPN is not pushing the Gateway (so hosts have different WAN access)

We will break down the examples command

```
Example:
  ./parallel-crawleresh.sh -r userName@10.7.0.6:22 -f https___shopify.dev.csv -n MyProject -w 190.60.50.60:80 -w 127.0.0.1
```

You specify as many worker hosts as desired `-w user@host:port` , note the port is the SSH port , need to be activated an accesible throughout all hosts via the LAN.
The host, user and port given on `-r` are needed and is the Ip address (or hostname), for the `MASTER_HOST`. It has to be reachable for all the `WORKER_HOST`'s
A `.csv` file with a list of links, see **rul_list_file format** below

We need to also specify a project directory name with `-n` . This is important, as the downloads will be done on each hosts environment variable `DOWN_PATH` for instance `/home/myuser/downloads` then we specify this subdirectory to be the working one for the fetched files.

As prior steps we need to allow on `sshd_config` to share environment variables as shown on the help command (not going to explain this again)
The usefulness of this is that , many hosts may have different working directories, it is better to specify them this way, also the main disk to be checked in order to not to run out of space has to be specified there, and is per host.


## Functioning of the command

It will initiate a download of each file, allocating files to be downloaded to each `worker_host` according to their availability.
Each `worker_host` will store their partial index on its machine in `${DOWN_PATH}/${PROJECT_NAME}` for instance `/home/myuser/downloads/shopify`.

If the `host_worker` disk goes below 500MB of usable storage, been this disk the one setted with `${MAIN_DISK}` for instance `/dev/sdc`  ,  it will dump its index to `MASTER_HOST` resuming the index as soon as it has got storage.

Upon completion of the url_list_file , each `host_worker` will transfer all the files to `MASTER_HOST`

## url_list_file format

It has to be made of comma `,` separator , two fields.
Firstone the url, the secondone the last exit code of wget, been this `-1` if it hasn't been yet runned

For instance `https___shopify.dev.csv`

```
https://shopify.dev/api/admin-graphql/2021-10/enums/FileErrorCode,0
https://shopify.dev/api/admin-graphql/2021-10/enums/MediaErrorCode,0
https://shopify.dev/api/admin-graphql/2021-10/input-objects/AppUsagePricingInput,8
https://shopify.dev/api/admin-graphql/2021-10/mutations/customerpaymentmethodrevoke,-1
https://shopify.dev/api/admin-graphql/2021-10/objects/Customer,-1
https://shopify.dev/api/admin-graphql/2021-10/objects/CustomerCreditCard,-1
```

Upon running the script it will take the ones that haven't been attempted to be downloaded `-1` , and cycle through them


## Dependencies

- `bash`
- `ssh`
- `parallel` (GNU parallel)
- `wget`
- `rsync`
