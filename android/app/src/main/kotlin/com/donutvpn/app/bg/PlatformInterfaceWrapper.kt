package com.donutvpn.app.bg

import android.annotation.SuppressLint
import android.content.pm.PackageManager
import android.net.NetworkCapabilities
import android.os.Build
import android.util.Log
import com.donutvpn.app.Application
import com.donutvpn.core.libbox.InterfaceUpdateListener
import com.donutvpn.core.libbox.Libbox
import com.donutvpn.core.libbox.NetworkInterfaceIterator
import com.donutvpn.core.libbox.PlatformInterface
import com.donutvpn.core.libbox.StringIterator
import com.donutvpn.core.libbox.TunOptions
import com.donutvpn.core.libbox.WIFIState
import java.net.Inet6Address
import java.net.InterfaceAddress
import java.net.NetworkInterface
import java.util.Enumeration
import com.donutvpn.core.libbox.NetworkInterface as LibboxNetworkInterface



import android.system.OsConstants
import com.donutvpn.core.libbox.AutoRedirectHandler
import com.donutvpn.core.libbox.AutoRedirectSession
import com.donutvpn.core.libbox.BridgeOptions
import com.donutvpn.core.libbox.BridgeSession
import com.donutvpn.core.libbox.ConnectionOwner
import com.donutvpn.core.libbox.LocalDNSTransport
import com.donutvpn.core.libbox.NeighborUpdateListener
import com.donutvpn.core.libbox.PlatformUser
import com.donutvpn.core.libbox.ShellSession
import java.security.KeyStore
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

interface PlatformInterfaceWrapper : PlatformInterface {
    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun autoDetectInterfaceControl(fd: Int) {
    }

    override fun openTun(options: TunOptions): Int {
        // Never throw across the gomobile JNI boundary.
        Log.e("PlatformInterface", "openTun is not supported on this interface")
        return -1
    }

    fun useProcFS(): Boolean =  Build.VERSION.SDK_INT < Build.VERSION_CODES.Q

    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int
    ): ConnectionOwner {
        // Always return a valid object. Never return null.
        val owner = ConnectionOwner()
        try {
            Log.d("PlatformInterface", "findConnectionOwner called for $destinationAddress:$destinationPort")

            // TODO: If you have safe, non-throwing logic to get the UID, put it here.
            // For now, we default to INVALID_UID (-1) to guarantee no JNI crashes.
            // Do NOT call external functions here unless you are 100% sure they cannot throw or return null.

            owner.userId = -1 // Process.INVALID_UID

            Log.d("PlatformInterface", "findConnectionOwner returning safely with userId: ${owner.userId}")
        } catch (t: Throwable) {
            // Catch Throwable, not just Exception, to catch Errors and RuntimeExceptions
            Log.e("PlatformInterface", "findConnectionOwner caught Throwable, returning INVALID_UID", t)
            owner.userId = -1
        }
        return owner
    }

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        try {
            DefaultNetworkMonitor.setListener(listener)
        } catch (t: Throwable) {
            Log.e("PlatformInterface", "startDefaultInterfaceMonitor failed", t)
        }
    }

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {
        try {
            DefaultNetworkMonitor.setListener(null)
        } catch (t: Throwable) {
            Log.e("PlatformInterface", "closeDefaultInterfaceMonitor failed", t)
        }
    }

    override fun getInterfaces(): NetworkInterfaceIterator =
        try {
            buildInterfaces()
        } catch (t: Throwable) {
            Log.e("PlatformInterface", "getInterfaces failed", t)
            InterfaceArray(emptyList<LibboxNetworkInterface>().iterator())
        }

    private fun buildInterfaces(): NetworkInterfaceIterator {
        val networks = Application.connectivity.allNetworks
        val networkInterfaces = NetworkInterface.getNetworkInterfaces().toList()
        val interfaces = mutableListOf<LibboxNetworkInterface>()
        for (network in networks) {
            val boxInterface = LibboxNetworkInterface()
            val linkProperties = Application.connectivity.getLinkProperties(network) ?: continue
            val networkCapabilities =
                Application.connectivity.getNetworkCapabilities(network) ?: continue
            boxInterface.name = linkProperties.interfaceName
            val networkInterface =
                networkInterfaces.find { it.name == boxInterface.name } ?: continue
            boxInterface.dnsServer =
                StringArray(linkProperties.dnsServers.mapNotNull { it.hostAddress }.iterator())
            boxInterface.type =
                when {
                    networkCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> Libbox.InterfaceTypeWIFI
                    networkCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> Libbox.InterfaceTypeCellular
                    networkCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> Libbox.InterfaceTypeEthernet
                    else -> Libbox.InterfaceTypeOther
                }
            boxInterface.index = networkInterface.index
            runCatching {
                boxInterface.mtu = networkInterface.mtu
            }.onFailure {
                Log.e(
                    "PlatformInterface",
                    "failed to get mtu for interface ${boxInterface.name}",
                    it,
                )
            }
            boxInterface.addresses =
                StringArray(
                    networkInterface.interfaceAddresses.mapTo(mutableListOf()) { it.toPrefix() }
                        .iterator(),
                )
            var dumpFlags = 0
            if (networkCapabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                dumpFlags = OsConstants.IFF_UP or OsConstants.IFF_RUNNING
            }
            if (networkInterface.isLoopback) {
                dumpFlags = dumpFlags or OsConstants.IFF_LOOPBACK
            }
            if (networkInterface.isPointToPoint) {
                dumpFlags = dumpFlags or OsConstants.IFF_POINTOPOINT
            }
            if (networkInterface.supportsMulticast()) {
                dumpFlags = dumpFlags or OsConstants.IFF_MULTICAST
            }
            boxInterface.flags = dumpFlags
            boxInterface.metered =
                !networkCapabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
            interfaces.add(boxInterface)
        }
        return InterfaceArray(interfaces.iterator())
    }

    override fun underNetworkExtension(): Boolean = false

    override fun includeAllNetworks(): Boolean = false

    override fun clearDNSCache() {
    }

    override fun checkPlatformShell() {
    }

    override fun closeNeighborMonitor(listener: NeighborUpdateListener) {
    }

    override fun createAutoRedirect(
        key: ByteArray,
        handler: AutoRedirectHandler,
    ): AutoRedirectSession? = null

    override fun createBridge(options: BridgeOptions): BridgeSession? = null

    override fun lookupSFTPServer(): String = ""

    override fun lookupUser(username: String): PlatformUser? = null

    override fun openShellSession(
        user: PlatformUser,
        command: String,
        args: StringIterator,
        workingDirectory: String,
        rows: Int,
        cols: Int,
    ): ShellSession? = null

    override fun readSystemSSHHostKey(): String = ""

    override fun registerMyInterface(name: String) {
    }

    override fun startNeighborMonitor(listener: NeighborUpdateListener) {
    }

    override fun tailscaleHostname(): String = ""

    override fun usePlatformAutoRedirect(): Boolean = false

    override fun usePlatformBridge(): Boolean = false

    override fun usePlatformShell(): Boolean = false

    override fun readWIFIState(): WIFIState? =
        try {
            readWIFIStateInternal()
        } catch (t: Throwable) {
            Log.e("PlatformInterface", "readWIFIState failed", t)
            null
        }

    private fun readWIFIStateInternal(): WIFIState? {
        @Suppress("DEPRECATION")
        val wifiInfo =
            Application.wifiManager.connectionInfo ?: return null
        var ssid = wifiInfo.ssid
        if (ssid == "<unknown ssid>") {
            return WIFIState("", "")
        }
        if (ssid.startsWith("\"") && ssid.endsWith("\"")) {
            ssid = ssid.substring(1, ssid.length - 1)
        }
        return WIFIState(ssid, wifiInfo.bssid)
    }

    override fun localDNSTransport(): LocalDNSTransport? = LocalResolver

    override fun systemCertificates(): StringIterator =
        try {
            readSystemCertificates()
        } catch (t: Throwable) {
            Log.e("PlatformInterface", "systemCertificates failed", t)
            StringArray(emptyList<String>().iterator())
        }

    @OptIn(ExperimentalEncodingApi::class)
    private fun readSystemCertificates(): StringIterator {
        val certificates = mutableListOf<String>()
        val keyStore = KeyStore.getInstance("AndroidCAStore")
        if (keyStore != null) {
            keyStore.load(null, null)
            val aliases = keyStore.aliases()
            while (aliases.hasMoreElements()) {
                val cert = keyStore.getCertificate(aliases.nextElement())
                certificates.add(
                    "-----BEGIN CERTIFICATE-----\n" + Base64.encode(cert.encoded) + "\n-----END CERTIFICATE-----",
                )
            }
        }
        return StringArray(certificates.iterator())
    }

    private class InterfaceArray(private val iterator: Iterator<LibboxNetworkInterface>) : NetworkInterfaceIterator {
        override fun hasNext(): Boolean = iterator.hasNext()

        override fun next(): LibboxNetworkInterface = iterator.next()
    }

    class StringArray(private val iterator: Iterator<String>) : StringIterator {
        override fun len(): Int {
            // not used by core
            return 0
        }

        override fun hasNext(): Boolean = iterator.hasNext()

        override fun next(): String = iterator.next()
    }

    private fun InterfaceAddress.toPrefix(): String = if (address is Inet6Address) {
        "${Inet6Address.getByAddress(address.address).hostAddress}/$networkPrefixLength"
    } else {
        "${address.hostAddress}/$networkPrefixLength"
    }

    private val NetworkInterface.flags: Int
        @SuppressLint("SoonBlockedPrivateApi")
        get() {
            val getFlagsMethod = NetworkInterface::class.java.getDeclaredMethod("getFlags")
            return getFlagsMethod.invoke(this) as Int
        }
}