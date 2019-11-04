#!/bin/sh
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at:
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


# get ovs source always from master as its needed as dependency
cd /ovs;

# build and install
./boot.sh
./configure --localstatedir="/var" --sysconfdir="/etc" --prefix="/usr" \
--enable-ssl
make -j8; make install
cd /ovn

# build and install
./boot.sh
./configure --localstatedir="/var" --sysconfdir="/etc" --prefix="/usr" \
--enable-ssl --with-ovs-source=/ovs/ --with-ovs-build=/ovs/
make -j8; make install

cp /ovs/rhel/usr_lib_systemd_system_openvswitch.service /usr/lib/systemd/system/openvswitch.service
cp /ovs/rhel/usr_lib_systemd_system_ovsdb-server.service /usr/lib/systemd/system/ovsdb-server.service
cp /ovs/rhel/usr_lib_systemd_system_ovs-vswitchd.service.in /usr/lib/systemd/system/ovs-vswitchd.service
cp /ovn/rhel/usr_lib_systemd_system_ovn-controller.service /usr/lib/systemd/system/ovn-controller.service
cp /ovn/rhel/usr_lib_systemd_system_ovn-northd.service /usr/lib/systemd/system/ovn-northd.service

sed -i '/ExecStartPre/d' /usr/lib/systemd/system/ovs-vswitchd.service
sed -i '/begin_dpdk/d' /usr/lib/systemd/system/ovs-vswitchd.service
sed -i '/end_dpdk/d' /usr/lib/systemd/system/ovs-vswitchd.service

# remove unused packages to make the container light weight.
for i in $(package-cleanup --leaves --all);
    do dnf remove -y $i; dnf autoremove -y;
done


rm -rf /ovs; rm -rf /ovn
