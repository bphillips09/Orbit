import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:orbit/storage/storage_data.dart';
import 'package:orbit/serial_helper/serial_helper_interface.dart';
import 'package:orbit/logging.dart';

class ConnectionDialogs {
  const ConnectionDialogs._();
  static const String defaultNetworkHost = '172.22.255.252';
  static const String defaultNetworkUartPort = '3555';
  static const String defaultNetworkGpioPort = '4556';

  static Future<SerialTransport?> showConnectionType(
    BuildContext context, {
    bool barrierDismissible = false,
    String? message,
  }) async {
    return await showDialog<SerialTransport>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (BuildContext dialogContext) {
        final bool networkDisabled = (kIsWeb || kIsWasm);
        return PopScope(
          canPop: barrierDismissible,
          child: AlertDialog(
            title: const Text('Connection Type'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if ((message ?? '').trim().isNotEmpty) ...[
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        message!.trim(),
                        style: TextStyle(
                          color: Theme.of(dialogContext).colorScheme.error,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: FilledButton(
                            onPressed: () => Navigator.pop(
                                dialogContext, SerialTransport.serial),
                            child: const Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.usb, size: 28),
                                SizedBox(height: 8),
                                Text('Serial'),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Tooltip(
                            message: networkDisabled
                                ? 'Unavailable on web'
                                : 'Connect over network',
                            child: FilledButton.tonal(
                              onPressed: networkDisabled
                                  ? null
                                  : () => Navigator.pop(
                                      dialogContext, SerialTransport.network),
                              child: const Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.router, size: 28),
                                  SizedBox(height: 8),
                                  Text('Network'),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // Network settings prompt
  static Future<String?> showNetworkConfig(BuildContext context) async {
    return await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        final hostCtrl = TextEditingController(text: defaultNetworkHost);
        final uartCtrl = TextEditingController(text: defaultNetworkUartPort);
        final gpioCtrl = TextEditingController(text: defaultNetworkGpioPort);
        String? error;
        return StatefulBuilder(
          builder: (BuildContext ctx, StateSetter setStateDialog) {
            return AlertDialog(
              title: const Text('Network Settings'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: hostCtrl,
                      decoration: InputDecoration(
                        labelText: 'Host/IP',
                        hintText: 'e.g. $defaultNetworkHost',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: uartCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'UART Port',
                        hintText: 'e.g. 3555',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: gpioCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'GPIO Port',
                        hintText: 'e.g. 4556',
                      ),
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(ctx).colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, null),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    final host = hostCtrl.text.trim();
                    final uart = int.tryParse(uartCtrl.text.trim()) ?? -1;
                    final gpio = int.tryParse(gpioCtrl.text.trim());
                    bool inRange(int v) => v > 0 && v <= 65535;
                    if (host.isEmpty || !inRange(uart)) {
                      setStateDialog(() {
                        error = 'Enter a valid host and UART port.';
                      });
                      return;
                    }
                    String spec = '$host:$uart';
                    if (gpio != null && inRange(gpio)) {
                      spec = '$spec:$gpio';
                    }
                    Navigator.pop(dialogContext, spec);
                  },
                  child: const Text('Connect'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  static Future<int> showSerialPortPicker(
    BuildContext context, {
    required SerialHelper serialHelper,
    required StorageData storageData,
    bool canDismiss = false,
  }) async {
    List<String> comPorts = [];
    const String selectNewLabel = 'Select New...';

    Future<List<String>> loadPorts() async {
      comPorts.clear();
      var availablePorts = await serialHelper.listPorts();
      logger.d('Available ports: ${availablePorts.length}');
      for (var port in availablePorts) {
        var portName = await serialHelper.getPortName(port);
        logger.d('Port: $portName');
        if (portName.isEmpty) {
          portName = port.toString();
        }
        comPorts.add(portName);
      }
      if (kIsWeb || kIsWasm) {
        comPorts.add(selectNewLabel);
      }
      return comPorts;
    }

    Future<List<String>> portsFuture = loadPorts();

    final int? result = await showDialog<int>(
      barrierDismissible: canDismiss,
      context: context,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (BuildContext dialogContext, StateSetter setStateDialog) {
            return AlertDialog(
              title: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Select Serial Device...',
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                    ),
                  ),
                  if (!kIsWeb && !kIsWasm)
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: 'Refresh Ports',
                      onPressed: () {
                        setStateDialog(() {
                          portsFuture = loadPorts();
                        });
                      },
                    ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Close',
                    onPressed: () {
                      if (kIsWeb || kIsWasm) {
                        Navigator.pop(dialogContext, -1);
                        return;
                      }
                      Navigator.pop(dialogContext, -1);
                    },
                  ),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: FutureBuilder<List<String>>(
                  future: portsFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return Center(child: Text('Error: ${snapshot.error}'));
                    }
                    comPorts = snapshot.data ?? [];
                    return ListView.builder(
                      shrinkWrap: true,
                      itemCount: comPorts.length,
                      itemBuilder: (context, index) {
                        final label = comPorts[index];
                        return ListTile(
                          title: Text(label),
                          onTap: () async {
                            if ((kIsWeb || kIsWasm) &&
                                label == selectNewLabel) {
                              try {
                                await serialHelper.ensureSerialPermission();
                              } catch (_) {}
                              setStateDialog(() {
                                portsFuture = loadPorts();
                              });
                              return;
                            }
                            Navigator.pop(dialogContext, index);
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            );
          },
        );
      },
    );
    return result ?? -1;
  }

  static Future<(String, Object?)> selectSerialPort(
    BuildContext context, {
    required SerialHelper serialHelper,
    required StorageData storageData,
    bool canDismiss = false,
  }) async {
    String lastPortString = '';
    Object? lastPortObject;

    try {
      if (!kIsWeb && !kIsWasm) {
        await serialHelper.ensureSerialPermission();
      }
    } catch (_) {}

    var availablePorts = await serialHelper.listPorts();
    if (availablePorts.isNotEmpty || kIsWeb || kIsWasm) {
      if (!context.mounted) {
        return ('', null);
      }
      int portIndex = await showSerialPortPicker(
        context,
        serialHelper: serialHelper,
        storageData: storageData,
        canDismiss: canDismiss,
      );
      availablePorts = await serialHelper.listPorts();
      if (portIndex < 0 || portIndex >= availablePorts.length) {
        // Selection out of bounds or cancelled
      } else {
        if (!kIsWeb && !kIsWasm) {
          lastPortString = availablePorts[portIndex] as String;
        } else if (portIndex < availablePorts.length) {
          lastPortObject = availablePorts[portIndex];
        }
      }
    } else if (availablePorts.isEmpty && !kIsWeb && !kIsWasm) {
      if (!context.mounted) {
        return ('', null);
      }
      await showSerialPortPicker(
        context,
        serialHelper: serialHelper,
        storageData: storageData,
        canDismiss: canDismiss,
      );
      return ('', null);
    }

    if (!kIsWeb && !kIsWasm && lastPortString.isNotEmpty) {
      storageData.save(SaveDataType.lastPort, lastPortString);
    }

    return (lastPortString, lastPortObject);
  }
}
