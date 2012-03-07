/*
	Copyright (c) 2011, T. Kroes <t.kroes@tudelft.nl>
	All rights reserved.

	Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

	- Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
	- Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
	- Neither the name of the TU Delft nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.
	
	THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

#pragma once

#include "Transport.cuh"

DNI ScatterEvent SampleRay(Ray R, CRNG& RNG)
{
	ScatterEvent SE[3] = { ScatterEvent(ScatterEvent::ErVolume), ScatterEvent(ScatterEvent::Light), ScatterEvent(ScatterEvent::Reflector) };

	SampleVolume(R, RNG, SE[0]);
	IntersectLights(R, SE[1], true);
	IntersectReflectors(R, SE[2]);

	float T = FLT_MAX;

	ScatterEvent NearestRS(ScatterEvent::ErVolume);

	for (int i = 0; i < 3; i++)
	{
		if (SE[i].Valid && SE[i].T < T)
		{
			NearestRS = SE[i];
			T = SE[i].T;
		}
	}

	return NearestRS;
}

KERNEL void KrnlSingleScattering(FrameBuffer* pFrameBuffer)
{
	const int X		= blockIdx.x * blockDim.x + threadIdx.x;
	const int Y		= blockIdx.y * blockDim.y + threadIdx.y;

	if (X >= pFrameBuffer->Resolution[0] || Y >= pFrameBuffer->Resolution[1])
		return;
	
	CRNG RNG(pFrameBuffer->CudaRandomSeeds1.GetPtr(X, Y), pFrameBuffer->CudaRandomSeeds2.GetPtr(X, Y));

	Vec2f ScreenPoint;

	ScreenPoint[0] = gCamera.Screen[0][0] + (gCamera.InvScreen[0] * (float)X);
	ScreenPoint[1] = gCamera.Screen[1][0] + (gCamera.InvScreen[1] * (float)Y);
	
	Ray Re;

	Re.O	= ToVec3f(gCamera.Pos);
	Re.D	= Normalize(ToVec3f(gCamera.N) + (ScreenPoint[0] * ToVec3f(gCamera.U)) - (ScreenPoint[1] * ToVec3f(gCamera.V)));
	Re.MinT	= gCamera.ClipNear;
	Re.MaxT	= gCamera.ClipFar;

	if (gCamera.ApertureSize != 0.0f)
	{
		const Vec2f LensUV = gCamera.ApertureSize * ConcentricSampleDisk(RNG.Get2());

		const Vec3f LI = ToVec3f(gCamera.U) * LensUV[0] + ToVec3f(gCamera.V) * LensUV[1];

		Re.O += LI;
		Re.D = Normalize(Re.D * gCamera.FocalDistance - LI);
	}

	ColorXYZf Lv = SPEC_BLACK, Li = SPEC_BLACK, Throughput = ColorXYZf(1.0f);

	const ScatterEvent SE = SampleRay(Re, RNG);

	LightingSample LS;

	LS.LargeStep(RNG);

	if (SE.Valid && SE.Type == ScatterEvent::ErVolume)
		Lv += UniformSampleOneLightVolume(SE, RNG, LS);

		switch (SE.Type)
		{
			case ScatterEvent::ErVolume:
			
			
			
			case ScatterEvent::Light:
			{
				CVolumeShader Shader(CVolumeShader::Brdf, SE.N, SE.Wo, ColorXYZf(0.5f), ColorXYZf(0.5f), 5.0f, 100.0f);

				Vec3f Wi; float BsdfPdf;

				ColorXYZf F = Shader.SampleF(-Re.D, Wi, BsdfPdf, LS.m_BsdfSample);

				Lv += UniformSampleOneLight(SE, RNG, Shader, LS);//SE.Le / DistanceSquared(Re.O, SE.P, Shader);

				Re.O = SE.P;
				Re.D = Wi;

				// Throughput *= F;
				// Throughput /= BsdfPdf;
				break;
			}

			case ScatterEvent::Reflector:
			{
				CVolumeShader Shader(CVolumeShader::Brdf, SE.N, SE.Wo, ColorXYZf(0.5f), ColorXYZf(0.5f), 5.0f, 100.0f);

				Vec3f Wi; float BsdfPdf;

				ColorXYZf F = Shader.SampleF(-Re.D, Wi, BsdfPdf, LS.m_BsdfSample);

				ColorXYZf Li = UniformSampleOneLight(SE, RNG, Shader, LS);
				
				Li *= F;
				Li /= BsdfPdf;

				if (!F.IsBlack() && BsdfPdf > 0.0f)
				{
					Lv += Throughput * Li;//SE.Le / DistanceSquared(Re.O, SE.P, Shader);


					Re.O = SE.P;
					Re.D = Wi;
				}

				break;
			}
			
		}

	
	ColorXYZAf L(Lv.GetX(), Lv.GetY(), Lv.GetZ(), SE.Valid >= 0 ? 1.0f : 0.0f);

	pFrameBuffer->CudaFrameEstimateXyza.Set(L, X, Y);
/**/
//	float Lf = pFrameBuffer->CudaFrameEstimateXyza.GetPtr(X, Y)->Y(), Lr = pFrameBuffer->CudaRunningEstimateXyza.GetPtr(X, Y)->Y();

//	pFrameBuffer->CudaRunningStats.GetPtr(X, Y)->Push(fabs(Lf - Lr), gScattering.NoIterations);
}

void SingleScattering(FrameBuffer* pFrameBuffer, int Width, int Height)
{
	const dim3 BlockDim(KRNL_SINGLE_SCATTERING_BLOCK_W, KRNL_SINGLE_SCATTERING_BLOCK_H);
	const dim3 GridDim((int)ceilf((float)Width / (float)BlockDim.x), (int)ceilf((float)Height / (float)BlockDim.y));

	KrnlSingleScattering<<<GridDim, BlockDim>>>(pFrameBuffer);
	cudaThreadSynchronize();
	HandleCudaKernelError(cudaGetLastError(), "Single Scattering");
}