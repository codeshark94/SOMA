#include "OpenOBSBOTUVCTransport.hpp"
#include "OpenOBSBOTContract.hpp"

#include <iomanip>
#include <iostream>
#include <string>

int main(int argc, char **argv) {
    const bool readAttitude = argc == 2 && std::string(argv[1]) == "--read-attitude";
    const bool contractOnly = argc == 1 || (argc == 2 && std::string(argv[1]) == "--contract");
    if (!readAttitude && !contractOnly) {
        std::cerr << "Usage: soma-obsbot-probe [--contract|--read-attitude]\n";
        return 64;
    }
    soma::OpenOBSBOTUVCTransport transport;
    std::string error;
    if (!transport.openDetected(error)) {
        std::cerr << "soma-obsbot-probe: " << error << '\n';
        return 2;
    }
    std::cout << soma::openOBSBOTContractLine(transport.identity()) << '\n';
    if (!readAttitude) return 0;
    double pitch = 0;
    double pan = 0;
    if (transport.readAttitude(pitch, pan) != 0) {
        std::cerr << "soma-obsbot-probe: UVC attitude read failed\n";
        return 3;
    }
    std::cout << std::fixed << std::setprecision(3)
              << "SOMA_GIMBAL_ATTITUDE pitch=" << pitch
              << " pan=" << pan
              << " source=open_uvc_xu\n";
    return 0;
}
