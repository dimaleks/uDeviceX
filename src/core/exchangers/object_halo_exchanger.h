#pragma once

#include "exchanger_interfaces.h"

#include <core/containers.h>
#include <core/pvs/extra_data/packers.h>

#include <memory>

class ObjectVector;
class ObjectsPacker;

class ObjectHaloExchanger : public Exchanger
{
public:
    ObjectHaloExchanger();
    ~ObjectHaloExchanger();

    void attach(ObjectVector *ov, float rc, const std::vector<std::string>& extraChannelNames);

    PinnedBuffer<int>& getSendOffsets(int id);
    PinnedBuffer<int>& getRecvOffsets(int id);
    PinnedBuffer<int>& getOrigins    (int id);

protected:
    std::vector<float> rcs;
    std::vector<ObjectVector*> objects;
    std::vector<std::unique_ptr<ObjectsPacker>> packers;

    std::vector<std::unique_ptr<PinnedBuffer<int>>> origins;

    void prepareSizes(int id, cudaStream_t stream) override;
    void prepareData (int id, cudaStream_t stream) override;
    void combineAndUploadData(int id, cudaStream_t stream) override;
    bool needExchange(int id) override;
};